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
final class LocationAuthorizationRequester: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
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

    /// Created on the MAIN queue in `requestAuthorization()`, never before
    /// -- see that method for why that is load-bearing. Optional only
    /// because it cannot exist until that hop happens; written once, then
    /// only read.
    /// False when this instance is OBSERVING rather than asking. The two
    /// differ in exactly two places -- whether `requestWhenInUseAuthorization`
    /// is called, and whether a `.notDetermined` callback counts as the
    /// answer -- so they share everything else rather than being two
    /// near-identical classes that can drift apart.
    private let asking: Bool

    private var manager: CLLocationManager?
    private let log: Logger
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocationHelperAuthorization, Never>?
    private var settled: LocationHelperAuthorization?
    private var timeoutTask: Task<Void, Never>?

    /// How long to wait for the manager to report a status we did not ask
    /// for. Short, because the answer arrives on the first delegate
    /// callback; this only bounds a manager that never calls back at all.
    static let settleTimeout: TimeInterval = 3

    init(
        log: Logger,
        timeout: TimeInterval = LocationAuthorizationRequester.decisionTimeout,
        asking: Bool = true
    ) {
        self.log = log
        self.timeout = timeout
        self.asking = asking
        super.init()
    }

    /// Returns the settled authorization. Never throws and never hangs:
    /// every path out resolves, because the caller has a transaction to end
    /// and an XPC reply to send whatever the user did.
    ///
    /// EVERYTHING CORELOCATION TOUCHES HAPPENS ON THE MAIN QUEUE, and that
    /// is load-bearing rather than tidy. `CLLocationManager` delivers its
    /// delegate callbacks on the run loop of the thread that CREATED it,
    /// and this is reached from a `Task` spun off the XPC handler -- a
    /// dispatch thread with no run loop. MEASURED on the first live run,
    /// 2026-09-01: Steve approved the prompt and no callback ever arrived,
    /// so the 120s deadline elapsed and only its fallback read of
    /// `authorizationStatus` reported the grant. It "worked" 128 seconds
    /// late, which in the UI is a two-minute spinner in front of a user who
    /// already answered. `LocationResolver` documents this same hazard on
    /// its own `stopUpdatingLocation` hop; this file had to learn it again.
    ///
    /// `requestWhenInUseAuthorization()` is called UNCONDITIONALLY rather
    /// than behind a status check. It is a documented no-op once the user
    /// has answered, and assigning the delegate provokes a callback
    /// carrying the real status either way -- so an already-decided process
    /// resolves in milliseconds on that callback. The status check this
    /// replaced read `authorizationStatus` synchronously right after
    /// constructing the manager, which is the same unpopulated-
    /// `.notDetermined` race bluegull-aqi-hib.4 fixed on the resolution
    /// side: it would have sent an already-authorized helper down the
    /// asking path to wait out the whole deadline.
    func requestAuthorization() async -> LocationHelperAuthorization {
        await resolve()
    }

    /// The helper's CURRENT grant, without asking for one -- what every
    /// ordinary wake records, so a grant revoked in System Settings shows
    /// up on the next wake instead of never.
    ///
    /// Waits for the first delegate callback rather than reading
    /// `authorizationStatus` off a freshly-constructed manager. That read
    /// is `.notDetermined` for the first moments whatever the real grant
    /// is -- the same race bluegull-aqi-hib.4 fixed in
    /// `SystemLocationProvider`. MEASURED 2026-09-01: with the grant
    /// demonstrably in place, the helper recorded
    /// `authorization: notDetermined` into the shared state the app reads,
    /// which would have had hib.7 tell an authorized user they had no
    /// permission and the app offer to turn on something already on.
    static func settledAuthorization(log: Logger) async -> LocationHelperAuthorization {
        await LocationAuthorizationRequester(log: log, timeout: settleTimeout, asking: false).resolve()
    }

    private func resolve() async -> LocationHelperAuthorization {
        await MainActor.run {
            let manager = CLLocationManager()
            self.manager = manager
            // Assignment is itself the trigger for the first callback.
            manager.delegate = self
            guard self.asking else { return }
            self.log.notice("AUTH_REQUESTING at=\(stamp(), privacy: .public) -- prompt should appear now")
            manager.requestWhenInUseAuthorization()
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            // The callback can already have landed -- the hop above has
            // run by now. `settled` records an answer whether or not
            // anyone is waiting on it yet, which is what makes that safe.
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
                let status = await MainActor.run { self.manager?.authorizationStatus ?? .notDetermined }
                self.finish(Self.map(status))
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
        // When ASKING, `.notDetermined` here is the callback CoreLocation
        // fires on delegate assignment, before the user has touched
        // anything -- not an answer. Waiting is correct; resolving on it
        // would report "no grant" the instant we asked.
        //
        // When OBSERVING, that same callback IS the answer: it is the
        // first moment `authorizationStatus` is trustworthy, and
        // `.notDetermined` is a perfectly real state for a helper whose
        // first run has not happened yet.
        guard !asking || authorization != .notDetermined else { return }
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


}
