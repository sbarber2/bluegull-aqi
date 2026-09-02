import Foundation
import ServiceManagement
import BluegullAQIKit
import os

/// The container app's side of the location helper agent
/// (bluegull-aqi-hib.3/hib.11): register and unregister it via
/// `SMAppService`, read back what the system thinks its state is, and start
/// it on demand.
///
/// Only the app can do any of this. A widget extension cannot -- app
/// extensions cannot spawn processes or call `SMAppService` -- which is why
/// "the first widget starts the helper" was never a possible design and the
/// helper has to be owned by the app that may itself rarely be opened.
///
/// Deliberately a thin wrapper around system calls, not unit tested, same
/// reasoning as `AQIRefreshController` and `LocationPermissionRequester`:
/// everything here either succeeds or fails inside `SMAppService`/launchd,
/// with no logic of ours to exercise. What IS testable -- the job the helper
/// runs -- lives in `HelperRefreshJob` in the package. Verification for this
/// half is bluegull-aqi-hib.9's observational plan.
///
/// NOT wired into app launch. Registering the agent makes it start prompting
/// for location on the system's own schedule, which is precisely the
/// uncontrolled first run bluegull-aqi-hib.6 exists to prevent -- that bead
/// owns when `register()` is called and what the user sees first. This type
/// is the mechanism; hib.6 is the policy.
enum LocationHelperController {
    private static let log = Logger(
        subsystem: LocationHelperIdentity.logSubsystem,
        category: "helper-controller"
    )

    private static var service: SMAppService {
        SMAppService.agent(plistName: LocationHelperIdentity.plistName)
    }

    /// What the system currently thinks of the agent. `.requiresApproval` is
    /// the one worth acting on: an SMAppService background item is enabled
    /// by default but appears in System Settings > General > Login Items &
    /// Extensions, where the user can switch it off at any time. The agent
    /// then silently stops and nothing tells the app -- failure that is
    /// invisible and deferred, which is strictly worse than a denial that
    /// fails loudly at a moment the user understands. Surfacing it is
    /// bluegull-aqi-hib.7.
    static var status: SMAppService.Status { service.status }

    /// `status` translated into the shared vocabulary the widget can also
    /// read (bluegull-aqi-hib.7). `SMAppService` is unavailable to an app
    /// extension, so the app is the only process that can answer this, and
    /// `LocationHelperStatusStore` is where it writes the answer down.
    static var availability: LocationHelperAvailability {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        // A status the framework grows later is safer reported as "needs
        // attention" than silently as "fine" -- the whole point of this
        // issue is that failure here is otherwise invisible.
        @unknown default: .unreachable
        }
    }

    /// Registers the agent, re-registering if it was already registered.
    ///
    /// The unregister-first step is not defensive tidying: SMAppService.h
    /// states that if the plist or the executable changes, the service must
    /// be re-registered or it may not launch, and recommends unregistering
    /// first when the executable changed. Every app update changes the
    /// executable, so a plain `register()` on an existing registration is
    /// the stale-agent bug waiting to happen -- built in here from the
    /// start rather than debugged later from a helper that quietly stopped
    /// waking.
    @discardableResult
    static func register() -> Result<SMAppService.Status, Error> {
        let service = self.service
        if service.status == .enabled {
            try? service.unregister()
        }
        do {
            try service.register()
            log.notice("HELPER_REGISTERED status=\(describe(service.status), privacy: .public)")
            return .success(service.status)
        } catch {
            let ns = error as NSError
            log.error("""
            HELPER_REGISTER_FAILED domain=\(ns.domain, privacy: .public) \
            code=\(ns.code, privacy: .public) status=\(describe(service.status), privacy: .public)
            """)
            return .failure(error)
        }
    }

    /// Removes the agent AND its Background Task Management record -- the
    /// row in Login Items & Extensions. `launchctl bootout` alone only stops
    /// a running process and leaves that record behind, which is how a spike
    /// can look uninstalled and still be registered.
    @discardableResult
    static func unregister() -> Result<Void, Error> {
        do {
            try service.unregister()
            log.notice("HELPER_UNREGISTERED")
            return .success(())
        } catch {
            let ns = error as NSError
            log.error("HELPER_UNREGISTER_FAILED domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            return .failure(error)
        }
    }

    /// What the helper reported back.
    struct Response {
        /// The helper's own location grant as it saw it -- the app cannot
        /// read this any other way (see `LocationHelperStatusStore`).
        let authorization: LocationHelperAuthorization
        /// `HelperRefreshJob.Outcome.label`, or nil if the helper didn't run
        /// a refresh (e.g. it was refused authorization).
        let outcome: String?
    }

    /// Starts the helper now and asks it to refresh, rather than waiting for
    /// its activity to fire (bluegull-aqi-hib.11). nil if it could not be
    /// reached at all -- which is a genuinely different state from any
    /// answer it could give, and the one bluegull-aqi-hib.7 has to explain.
    static func refreshNow(timeout: TimeInterval = 30) async -> Response? {
        await send(action: LocationHelperIdentity.xpcRefreshAction, timeout: timeout)
    }

    /// bluegull-aqi-hib.6's first run: starts the helper and has it ask for
    /// the location grant, then fetch if it gets one.
    ///
    /// The long default deadline is the point -- the helper holds a launchd
    /// transaction across the user reading a system dialog, and this call is
    /// what the app's "waiting for permission" state is waiting on. Slightly
    /// longer than the helper's own 120s decision timeout so the helper's
    /// answer wins the race and the app reports what actually happened
    /// rather than a timeout of its own.
    ///
    /// THIS IS THE ONE CALL THAT CAN CONSUME THE SYSTEM PROMPT. It is
    /// one-shot and unrecoverable: CoreLocation refuses to re-prompt once
    /// answered and the locationd record cannot be cleared. Only the
    /// first-run flow should reach it, and only after the user has said yes
    /// to our own re-askable explanation.
    static func requestAuthorization(timeout: TimeInterval = 135) async -> Response? {
        await send(action: LocationHelperIdentity.xpcRequestAuthorizationAction, timeout: timeout)
    }

    /// Reaching a sandboxed agent from a sandboxed app at all depends on the
    /// service name being prefixed with a shared App Group identifier --
    /// `LocationHelperIdentity.machServiceName` -- which is the route that
    /// needs no extra entitlement and so does not grow the App Review
    /// surface. A `com.apple.security.temporary-exception.mach-lookup.
    /// global-name` would be the alternative and is a poor thing to carry
    /// into review.
    private static func send(action: String, timeout: TimeInterval) async -> Response? {
        await withCheckedContinuation { continuation in
            let connection = xpc_connection_create_mach_service(
                LocationHelperIdentity.machServiceName, nil, 0
            )
            // Resumed exactly once: XPC delivers either the reply or an
            // error object to the reply handler, never both, but a
            // connection that goes invalid can also surface on the event
            // handler, so the flag is what makes "once" true.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ response: Response?) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                xpc_connection_cancel(connection)
                continuation.resume(returning: response)
            }

            xpc_connection_set_event_handler(connection) { event in
                // XPC_ERROR_CONNECTION_INVALID is what a blocked or unknown
                // name produces -- i.e. the agent is not registered, or the
                // sandbox refused the lookup.
                guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
                // `finish` cancels the connection, and cancellation is
                // delivered here as an XPC error -- so every SUCCESSFUL
                // poke used to log a scary "unreachable" line right after
                // its own reply. Confirmed in the first live run's log,
                // 2026-09-01. Harmless to behaviour (the resume guard
                // already made the reply win) but corrosive to the log,
                // which is the only diagnostic bluegull-aqi-hib.7 and
                // hib.9 have for this process.
                guard !resumed.withLock({ $0 }) else { return }
                log.error("HELPER_UNREACHABLE action=\(action, privacy: .public) -- connection error on \(LocationHelperIdentity.machServiceName, privacy: .public)")
                finish(nil)
            }
            xpc_connection_resume(connection)

            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, LocationHelperIdentity.xpcActionKey, action)
            // NOT the main queue: a caller awaiting this may well be on it,
            // and dispatching the reply there too deadlocks until the
            // timeout and reads as "the helper never answered" from a
            // mechanism that worked -- a real, wasted debugging round in the
            // hib.11 spike.
            xpc_connection_send_message_with_reply(connection, message, DispatchQueue.global()) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    finish(nil)
                    return
                }
                let outcome = xpc_dictionary_get_string(reply, LocationHelperIdentity.xpcOutcomeKey)
                    .map { String(cString: $0) }
                let authorization = xpc_dictionary_get_string(reply, LocationHelperIdentity.xpcAuthorizationKey)
                    .map { String(cString: $0) }
                    .flatMap(LocationHelperAuthorization.init(rawValue:))
                    // A reply we can't parse an authorization out of is a
                    // protocol mismatch between app and helper -- almost
                    // certainly a stale agent that wasn't re-registered
                    // after an update. Reported as undetermined rather than
                    // as a refusal, because refusal copy is permanent and
                    // this state is fixable.
                    ?? .notDetermined
                log.notice("""
                HELPER_REPLIED action=\(action, privacy: .public) \
                authorization=\(authorization.rawValue, privacy: .public) \
                outcome=\(outcome ?? "(none)", privacy: .public) \
                helper_pid=\(xpc_dictionary_get_int64(reply, LocationHelperIdentity.xpcPidKey), privacy: .public)
                """)
                finish(Response(authorization: authorization, outcome: outcome))
            }

            // The helper may be doing a real GPS fix and a network fetch --
            // or waiting on a human -- so this deadline is generous. But it
            // must exist, or a helper that never answers suspends the caller
            // forever, the same defect as bluegull-aqi-10h.22.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
