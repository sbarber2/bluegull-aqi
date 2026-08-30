// bluegull-aqi-hib.10 spike agent.
//
// Deliberately does no AQI work and touches no CoreLocation. Its only job is
// to answer: does an SMAppService-registered LaunchAgent actually get woken
// on a repeating schedule, from cold boot, with the container app never
// launched? The hib epic's whole lifecycle claim rests on that and nobody
// has tested it.
//
// The plist gives it NO RunAtLoad and NO KeepAlive in checkin mode, which is
// the shape hib.3 specifies -- so if anything runs this, it is launchd
// acting on the activity, which is exactly the thing in question.
//
// Everything is logged at .notice, NOT .debug: .debug is memory-only and
// would be gone by the time anyone reads it after a reboot, which is the
// one measurement that matters most here. All interpolations are marked
// public, or the unified log redacts them to <private> and the whole run is
// unreadable.

import Foundation
import os

let subsystem = "solutions.bluegull.hib10"
let log = Logger(subsystem: subsystem, category: "agent")

let environment = ProcessInfo.processInfo.environment
// "checkin"  -- criteria declared in the launchd plist's LaunchEvents, picked
//               up here with XPC_ACTIVITY_CHECK_IN. The variant that, if it
//               works, means the epic's on-demand design is real.
// "register" -- criteria supplied here in code, which is what hib.5 actually
//               specifies. Carries the bootstrap problem, so its plist needs
//               RunAtLoad for the very first start; see the README.
let mode = environment["HIB10_MODE"] ?? "checkin"
let activityName = environment["HIB10_ACTIVITY"] ?? "\(subsystem).\(mode).wake"
let interval = Int64(environment["HIB10_INTERVAL"] ?? "") ?? 300
let grace = Int64(environment["HIB10_GRACE"] ?? "") ?? 60

let pid = ProcessInfo.processInfo.processIdentifier
let launchedAt = Date()

/// Counts wakes within THIS process. Read together with the pid: if wake #2
/// carries a different pid from wake #1, the process exited in between and
/// launchd relaunched it -- which is question 4 (does it actually exit, or is
/// it just a resident process wearing an on-demand costume).
let wakeCount = OSAllocatedUnfairLock(initialState: 0)

func stamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

log.notice("""
PROCESS_START pid=\(pid, privacy: .public) ppid=\(getppid(), privacy: .public) \
mode=\(mode, privacy: .public) activity=\(activityName, privacy: .public) \
at=\(stamp(launchedAt), privacy: .public)
""")

let handler: xpc_activity_handler_t = { activity in
    let state = xpc_activity_get_state(activity)

    switch state {
    case XPC_ACTIVITY_STATE_CHECK_IN:
        // Reached only in checkin mode. Getting here at all is the answer to
        // question 1: launchd accepted a plist carrying LaunchEvents through
        // SMAppService registration and kept the criteria.
        log.notice("""
        ACTIVITY_CHECK_IN pid=\(pid, privacy: .public) \
        activity=\(activityName, privacy: .public) at=\(stamp(), privacy: .public) \
        -- criteria came from the launchd plist
        """)

    case XPC_ACTIVITY_STATE_RUN:
        let wake = wakeCount.withLock { count -> Int in
            count += 1
            return count
        }
        let sinceLaunch = Date().timeIntervalSince(launchedAt)
        log.notice("""
        ACTIVITY_RUN pid=\(pid, privacy: .public) wake=\(wake, privacy: .public) \
        secs_since_process_start=\(Int(sinceLaunch), privacy: .public) \
        activity=\(activityName, privacy: .public) at=\(stamp(), privacy: .public)
        """)

        // Bracket the "work" in a transaction, which is what EnableTransactions
        // + EnablePressuredExit read to decide the process is idle and
        // reapable. Deprecated since 10.10 but still the mechanism those two
        // plist keys are defined against, and it compiles clean from Swift.
        xpc_transaction_begin()
        Thread.sleep(forTimeInterval: 2)  // stand-in for resolve + fetch + cache write
        xpc_transaction_end()

        xpc_activity_set_state(activity, XPC_ACTIVITY_STATE_DONE)
        log.notice("""
        ACTIVITY_DONE pid=\(pid, privacy: .public) wake=\(wake, privacy: .public) \
        at=\(stamp(), privacy: .public) -- transaction ended, now idle and reapable
        """)

    default:
        log.notice("ACTIVITY_STATE pid=\(pid, privacy: .public) state=\(state, privacy: .public) at=\(stamp(), privacy: .public)")
    }
}

switch mode {
case "register":
    // hib.5's literal proposal: criteria in code. Note RequireNetworkConnectivity,
    // which hib.5 copies from weatherd, is NOT a public XPC activity constant --
    // it is absent from xpc/activity.h entirely, so it cannot be set here. That
    // is a finding, not an oversight.
    let criteria = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_int64(criteria, XPC_ACTIVITY_INTERVAL, interval)
    xpc_dictionary_set_int64(criteria, XPC_ACTIVITY_GRACE_PERIOD, grace)
    xpc_dictionary_set_bool(criteria, XPC_ACTIVITY_REPEATING, true)
    xpc_dictionary_set_bool(criteria, XPC_ACTIVITY_ALLOW_BATTERY, true)
    xpc_dictionary_set_string(criteria, XPC_ACTIVITY_PRIORITY, XPC_ACTIVITY_PRIORITY_UTILITY)
    log.notice("""
    REGISTER_IN_CODE pid=\(pid, privacy: .public) activity=\(activityName, privacy: .public) \
    interval=\(interval, privacy: .public) grace=\(grace, privacy: .public)
    """)
    xpc_activity_register(activityName, criteria, handler)

default:
    log.notice("REGISTER_CHECK_IN pid=\(pid, privacy: .public) activity=\(activityName, privacy: .public)")
    xpc_activity_register(activityName, XPC_ACTIVITY_CHECK_IN, handler)
}

// Log the way out. launchd's pressured exit arrives as SIGTERM; a SIGKILL
// leaves no line, which is itself informative when reading the log back.
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    let lifetime = Date().timeIntervalSince(launchedAt)
    log.notice("""
    PROCESS_EXIT pid=\(pid, privacy: .public) reason=SIGTERM \
    lifetime_secs=\(Int(lifetime), privacy: .public) \
    wakes_this_process=\(wakeCount.withLock { $0 }, privacy: .public) at=\(stamp(), privacy: .public)
    """)
    exit(0)
}
termination.resume()
signal(SIGTERM, SIG_IGN)

log.notice("IDLE pid=\(pid, privacy: .public) -- registered, waiting; nothing holds this process open")
dispatchMain()
