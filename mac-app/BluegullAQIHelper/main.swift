// The BlueGull AQI location helper agent (bluegull-aqi-hib).
//
// Exists because a macOS widget extension cannot resolve location -- proven
// across three spike rounds with every precondition satisfied, and not
// fixable by configuration: Apple's own Weather widget gets there via the
// PRIVATE com.apple.locationd.effective_bundle entitlement, which third
// parties cannot use. A separate bundle is a separate TCC identity and CAN
// hold its own grant, including headless under launchd. This is that bundle.
//
// SHAPE, and why it is an .app rather than a bare tool: CoreLocation needs a
// real Info.plist carrying NSLocationWhenInUseUsageDescription, and the
// spike measured a headless launchd-started LSUIElement .app getting a
// prompt in 0.2s, a grant at 5.4s and a fix at 35m accuracy
// (bluegull-aqi-hib.10 question 5). The bare `tool` shape was proven for
// activity wakes and mach services but never for CoreLocation, so this
// reuses the shape whose risky half is the half that was measured.
//
// LIFECYCLE, all measured in spike/hib10 rather than assumed:
//  - No RunAtLoad, no KeepAlive. The plist's LaunchEvents activity is the
//    only thing that starts this on a schedule; a mach service connection
//    from the app is the only other way in.
//  - Woken 247 times over 29 hours with the container app never launched,
//    and again 5m21s after a cold boot, from a plist-declared activity.
//  - It does NOT exit between wakes. EnablePressuredExit + EnableTransactions
//    plus correct transaction bracketing make it *eligible* for termination;
//    they do not reap an idle job. One pid stayed resident ~19.5 hours at
//    2.9 MB before jetsam idle-exited it (SIGKILL, no exit line in the log)
//    and launchd re-spawned it. That is the real steady state -- a small
//    resident process, not a process that comes and goes.
//
// Everything logs at .notice, never .debug: .debug is memory-only and is
// gone by the time anyone reads it back, which is the whole point of the
// log for a process nobody is watching when it runs. Interpolations are
// marked public or the unified log redacts them to <private>.

import AppKit
import BluegullAQIKit
import os

let log = Logger(
    subsystem: LocationHelperIdentity.logSubsystem,
    category: LocationHelperIdentity.logCategory
)

let pid = ProcessInfo.processInfo.processIdentifier
let launchedAt = Date()

func stamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// nil only if the App Group suite couldn't be opened -- there is nowhere to
/// write a reading, so there is no work to do. Logged loudly rather than
/// silently no-oping, because from the outside it looks identical to a
/// helper that is never woken at all.
let job = HelperRefreshJob()

/// Where the app finds out what happened here (bluegull-aqi-hib.6). It has
/// no other way: a location grant belongs to a bundle identifier and no API
/// lets one process read another bundle's TCC state, and under hib.6's
/// Option 1 the app holds no grant of its own to consult either.
let statusStore = UserDefaultsCacheStore().map(LocationHelperStatusStore.init(store:))

/// Runs one refresh and reports what happened. `reason` distinguishes the
/// ways in (scheduled activity vs the app poking us) in the log, which is
/// the only way to tell them apart after the fact.
///
/// Records the helper's authorization on EVERY run, not just the first:
/// there is no notification when a user revokes a grant in System Settings,
/// so a wake that discovers the revocation is the only way the app ever
/// learns about it.
@discardableResult
func runRefresh(reason: String) async -> String {
    guard let job else {
        log.error("REFRESH_SKIPPED reason=\(reason, privacy: .public) -- App Group suite unavailable")
        return "no-app-group"
    }
    let started = Date()
    let outcome = await job.run()
    log.notice("""
    REFRESH pid=\(pid, privacy: .public) reason=\(reason, privacy: .public) \
    outcome=\(outcome.label, privacy: .public) \
    secs=\(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) \
    at=\(stamp(), privacy: .public)
    """)
    statusStore?.record(
        authorization: LocationAuthorizationRequester.currentAuthorization(),
        lastOutcome: outcome.label
    )
    return outcome.label
}

/// bluegull-aqi-hib.6's first run. The only path on which this process asks
/// for a location grant.
///
/// The caller has already opened a transaction, and it stays open across the
/// whole of this -- including the unbounded wait for a human to read a
/// dialog. That is in direct tension with pressured exit everywhere else in
/// this process and is deliberate: the hib.10 probe held no transaction and
/// survived only because the answer arrived in 5.4 seconds.
func requestAuthorizationThenRefresh() async -> (authorization: LocationHelperAuthorization, outcome: String?) {
    let requester = LocationAuthorizationRequester(log: log)
    let authorization = await requester.requestAuthorization()

    // Fetch immediately on a grant rather than leaving the user with an
    // empty menu bar until the next scheduled wake -- they just said yes to
    // a thing whose entire purpose is showing a number.
    var outcome: String?
    if authorization == .authorized {
        outcome = await runRefresh(reason: "first-run")
    } else {
        statusStore?.record(authorization: authorization, lastOutcome: nil)
    }

    log.notice("""
    FIRST_RUN pid=\(pid, privacy: .public) \
    authorization=\(authorization.rawValue, privacy: .public) \
    outcome=\(outcome ?? "(none)", privacy: .public) at=\(stamp(), privacy: .public)
    """)
    return (authorization, outcome)
}

// MARK: - Scheduled wakes

// XPC_ACTIVITY_CHECK_IN, not a criteria dictionary built here: the criteria
// live in the launchd plist, so launchd knows the schedule at registration
// time and can start a helper that has never run. Registering them from code
// has a bootstrap hole -- code that has never run cannot register anything --
// which is why the spike's variant A needed RunAtLoad and this does not.
let activityHandler: xpc_activity_handler_t = { activity in
    switch xpc_activity_get_state(activity) {
    case XPC_ACTIVITY_STATE_CHECK_IN:
        log.notice("""
        ACTIVITY_CHECK_IN pid=\(pid, privacy: .public) \
        activity=\(LocationHelperIdentity.refreshActivityName, privacy: .public) \
        at=\(stamp(), privacy: .public)
        """)

    case XPC_ACTIVITY_STATE_RUN:
        // The transaction is what EnableTransactions/EnablePressuredExit
        // read to decide this process is busy. Opened before the async work
        // starts and closed on every path out of it -- an unbalanced one
        // pins the process open forever, which is the failure that made
        // bluegull-aqi-10h.22 (an unbounded requestLocation) worth fixing
        // before any of this was built.
        xpc_transaction_begin()
        Task {
            await runRefresh(reason: "activity")
            xpc_transaction_end()
            // Marks this occurrence complete so launchd schedules the next
            // one. Deliberately after the work, not before: DONE before the
            // fetch finishes would let the next interval start overlapping
            // this one.
            _ = xpc_activity_set_state(activity, XPC_ACTIVITY_STATE_DONE)
        }

    default:
        break
    }
}

xpc_activity_register(
    LocationHelperIdentity.refreshActivityName,
    XPC_ACTIVITY_CHECK_IN,
    activityHandler
)

// MARK: - On-demand start from the app

// Registration alone does not start this job -- measured runs=0 immediately
// after a successful SMAppService.register(), which is correct for a job
// with no RunAtLoad. So the app needs a way in at a moment of its own
// choosing, which bluegull-aqi-hib.6's first-run design depends on: a
// location prompt has to arrive while the user is still looking at the thing
// that asked for it, not hours later on the system's schedule.
//
// launchd starts this process on the first connection to the name below and
// hands the listener over; a job that fails to create a listener for a name
// it declares in MachServices leaves launchd holding the request forever.
let machServiceListener = xpc_connection_create_mach_service(
    LocationHelperIdentity.machServiceName,
    nil,
    UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
)

xpc_connection_set_event_handler(machServiceListener) { peer in
    // Anything that isn't a connection is an error object -- most usefully
    // XPC_ERROR_CONNECTION_INVALID, which is what arrives if launchd never
    // handed us the name at all.
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
        log.error("LISTENER_ERROR name=\(LocationHelperIdentity.machServiceName, privacy: .public)")
        return
    }
    xpc_connection_set_event_handler(peer) { message in
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        let action = xpc_dictionary_get_string(message, LocationHelperIdentity.xpcActionKey)
            .map { String(cString: $0) } ?? ""
        let reply = xpc_dictionary_create_reply(message)

        func send(authorization: LocationHelperAuthorization, outcome: String?) {
            guard let reply else { return }
            xpc_dictionary_set_string(reply, LocationHelperIdentity.xpcAuthorizationKey, authorization.rawValue)
            if let outcome {
                xpc_dictionary_set_string(reply, LocationHelperIdentity.xpcOutcomeKey, outcome)
            }
            xpc_dictionary_set_int64(reply, LocationHelperIdentity.xpcPidKey, Int64(pid))
            xpc_connection_send_message(peer, reply)
        }

        switch action {
        case LocationHelperIdentity.xpcRefreshAction:
            // Same bracketing as the activity path, and needed for the same
            // reason: without it launchd may consider this process idle
            // while a refresh the app is waiting on is still in flight.
            xpc_transaction_begin()
            Task {
                let outcome = await runRefresh(reason: "on-demand")
                send(authorization: LocationAuthorizationRequester.currentAuthorization(), outcome: outcome)
                xpc_transaction_end()
            }

        case LocationHelperIdentity.xpcRequestAuthorizationAction:
            // The transaction spans a human decision here, not just a fetch
            // -- see requestAuthorizationThenRefresh().
            xpc_transaction_begin()
            Task {
                let result = await requestAuthorizationThenRefresh()
                send(authorization: result.authorization, outcome: result.outcome)
                xpc_transaction_end()
            }

        default:
            log.error("UNKNOWN_ACTION action=\(action, privacy: .public)")
        }
    }
    xpc_connection_resume(peer)
}
xpc_connection_resume(machServiceListener)

// MARK: - Lifecycle

// launchd's pressured exit arrives as SIGTERM. A jetsam idle-exit is SIGKILL
// and leaves no line at all, which is itself the signal -- a gap in the log
// followed by a PROCESS_START with a new pid is what a reap looks like.
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    log.notice("""
    PROCESS_EXIT pid=\(pid, privacy: .public) reason=SIGTERM \
    lifetime_secs=\(Int(Date().timeIntervalSince(launchedAt)), privacy: .public) \
    at=\(stamp(), privacy: .public)
    """)
    exit(0)
}
termination.resume()
signal(SIGTERM, SIG_IGN)

log.notice("""
PROCESS_START pid=\(pid, privacy: .public) ppid=\(getppid(), privacy: .public) \
bundle=\(Bundle.main.bundleIdentifier ?? "(none)", privacy: .public) \
at=\(stamp(launchedAt), privacy: .public)
""")

// .accessory, and an NSApplication rather than dispatchMain(): CoreLocation
// wants a live main run loop, and this is the exact shape the hib.10 probe
// used when it successfully prompted and got a fix from a launchd-started
// process. No Dock icon, no menu bar, no windows -- LSUIElement in the
// Info.plist says the same thing declaratively.
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
