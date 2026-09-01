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

    /// Starts the helper now and asks it to refresh, rather than waiting for
    /// its activity to fire (bluegull-aqi-hib.11). Returns the helper's own
    /// `HelperRefreshJob.Outcome.label`, or nil if it could not be reached.
    ///
    /// Reaching a sandboxed agent from a sandboxed app at all depends on the
    /// service name being prefixed with a shared App Group identifier --
    /// `LocationHelperIdentity.machServiceName` -- which is the route that
    /// needs no extra entitlement and so does not grow the App Review
    /// surface. A `com.apple.security.temporary-exception.mach-lookup.
    /// global-name` would be the alternative and is a poor thing to carry
    /// into review.
    static func refreshNow(timeout: TimeInterval = 30) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = xpc_connection_create_mach_service(
                LocationHelperIdentity.machServiceName, nil, 0
            )
            // Resumed exactly once: XPC delivers either the reply or an
            // error object to the reply handler, never both, but a
            // connection that goes invalid can also surface on the event
            // handler, so the flag is what makes "once" true.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ label: String?) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                xpc_connection_cancel(connection)
                continuation.resume(returning: label)
            }

            xpc_connection_set_event_handler(connection) { event in
                // XPC_ERROR_CONNECTION_INVALID is what a blocked or unknown
                // name produces -- i.e. the agent is not registered, or the
                // sandbox refused the lookup.
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    log.error("HELPER_POKE_FAILED -- connection error on \(LocationHelperIdentity.machServiceName, privacy: .public)")
                    finish(nil)
                }
            }
            xpc_connection_resume(connection)

            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(
                message,
                LocationHelperIdentity.xpcActionKey,
                LocationHelperIdentity.xpcRefreshAction
            )
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
                log.notice("""
                HELPER_POKED outcome=\(outcome ?? "(none)", privacy: .public) \
                helper_pid=\(xpc_dictionary_get_int64(reply, LocationHelperIdentity.xpcPidKey), privacy: .public)
                """)
                finish(outcome)
            }

            // The helper may be doing a real GPS fix and a network fetch, so
            // this deadline is generous -- but it must exist, or a helper
            // that never answers suspends the caller forever, the same
            // defect as bluegull-aqi-10h.22.
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
