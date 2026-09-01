import CoreLocation
import BluegullAQIKit
import os

/// Asks for the location grant, and waits for the human to answer
/// (bluegull-aqi-hib.6).
///
/// This is the ONE place in the whole project that calls
/// `requestWhenInUseAuthorization`. `LocationResolver`/
/// `SystemLocationProvider` deliberately never do -- permission UX and
/// timing are policy, not resolution -- and under bluegull-aqi-hib.6's
/// Option 1 the app doesn't either, because it holds no location grant at
/// all any more. One grant, one asker.
///
/// Lives in the helper target rather than the package for that reason: the
/// package is linked into the app and the widget extension too, and a
/// prompt-triggering call sitting in shared code is the easiest way to
/// re-introduce the second prompt this whole design exists to prevent.
///
/// THE PROMPT IS ONE SHOT. CoreLocation refuses to re-prompt once answered
/// and the locationd record cannot be cleared (tccutil fails -10814), so a
/// refusal is permanent as far as this app is concerned. That asymmetry is
/// why the app gates this behind its own re-askable explanation rather than
/// calling it on launch.
final class LocationAuthorizationRequester: NSObject, CLLocationManagerDelegate {
    /// How long to hold the launchd transaction open waiting for an answer.
    ///
    /// This is in direct tension with pressured exit everywhere else in
    /// this process, and is deliberate rather than incidental: the hib.10
    /// probe held no transaction at all and survived only because the
    /// answer came in 5.4 seconds. A real person reading a dialog may take
    /// a minute; someone who walks away may take forever, which is what the
    /// bound is for. Two minutes is long enough that nobody who is actually
    /// answering loses, and short enough that an abandoned prompt doesn't
    /// pin a background process open indefinitely.
    static let decisionTimeout: TimeInterval = 120

    private let manager = CLLocationManager()
    private let log: Logger
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocationHelperAuthorization, Never>?
    private var settled: LocationHelperAuthorization?
    private var timeoutTask: Task<Void, Never>?

    init(log: Logger, timeout: TimeInterval = LocationAuthorizationRequester.decisionTimeout) {
        self.log = log
        self.timeout = timeout
        super.init()
    }

    /// Returns the settled authorization. Never throws and never hangs:
    /// every path out resolves, because the caller has a transaction to end
    /// and an XPC reply to send whatever the user did.
    func requestAuthorization() async -> LocationHelperAuthorization {
        manager.delegate = self

        // Assigning the delegate provokes CoreLocation's first
        // authorization callback, so this reads a settled value rather than
        // the momentarily-unpopulated `.notDetermined` that
        // bluegull-aqi-hib.4 fixed on the resolution side. Waiting for that
        // callback here would be the more symmetric thing to do, but this
        // path has a 120s budget anyway -- the check below only exists to
        // avoid asking when there is nothing to ask.
        let existing = Self.map(manager.authorizationStatus)
        if existing != .notDetermined {
            // Already answered, in either direction. Calling
            // `requestWhenInUseAuthorization` now would be a silent no-op,
            // which reads to a caller as "the user never responded."
            log.notice("AUTH_ALREADY_DECIDED status=\(existing.rawValue, privacy: .public)")
            return existing
        }

        log.notice("AUTH_REQUESTING at=\(stamp(), privacy: .public) -- prompt should appear now")
        manager.requestWhenInUseAuthorization()

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
                return
            }
            self.continuation = continuation
            timeoutTask = Task { [weak self, timeout] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.log.error("AUTH_NO_ANSWER after \(Int(timeout), privacy: .public)s -- giving up the transaction")
                // Deliberately reports what the status actually is rather
                // than inventing a refusal: an unanswered prompt is still
                // `.notDetermined`, and the user can still answer it later.
                // Calling it a refusal here would make the app show the
                // permanent, unrecoverable copy for a recoverable state.
                self.finish(Self.map(self.manager.authorizationStatus))
            }
            lock.unlock()
        }
    }

    /// Resolves once, whichever of the callback and the deadline wins, and
    /// records the answer even if nobody is waiting on it yet -- the
    /// callback can land before the continuation is installed.
    private func finish(_ authorization: LocationHelperAuthorization) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = authorization
        let continuation = self.continuation
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        continuation?.resume(returning: authorization)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = Self.map(manager.authorizationStatus)
        log.notice("AUTH_CHANGED status=\(authorization.rawValue, privacy: .public) at=\(stamp(), privacy: .public)")
        // `.notDetermined` here is the callback CoreLocation fires on
        // delegate assignment, before the user has touched anything -- not
        // an answer. Waiting is correct; resolving on it would report "no
        // grant" the instant we asked.
        guard authorization != .notDetermined else { return }
        finish(authorization)
    }

    static func map(_ status: CLAuthorizationStatus) -> LocationHelperAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .refused
        // macOS has exactly these four -- authorizedWhenInUse is
        // API_UNAVAILABLE(macos), and .authorized is a deprecated alias for
        // .authorizedAlways with the same raw value. So @unknown default is
        // reachable only from a genuinely new future case; .refused points
        // the user at System Settings, which is where any such state would
        // have to be resolved anyway.
        case .authorizedAlways: .authorized
        @unknown default: .refused
        }
    }

    /// The helper's current grant without asking for one -- what every
    /// ordinary wake records, so a grant revoked in System Settings shows up
    /// on the next wake instead of never.
    static func currentAuthorization() -> LocationHelperAuthorization {
        map(CLLocationManager().authorizationStatus)
    }
}
