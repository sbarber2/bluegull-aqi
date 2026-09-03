import CoreLocation
import BluegullAQIKit
import os

/// Asks for the location grant, and waits for the human to answer
/// (bluegull-aqi-hib.6) -- and separately, reads the grant without asking
/// (bluegull-aqi-hib.7).
///
/// This is the ONE place in the whole project that calls
/// `requestWhenInUseAuthorization`. `LocationResolver`/
/// `SystemLocationProvider` deliberately never do -- permission UX and
/// timing are policy, not resolution -- and under hib.6's Option 1 the app
/// doesn't either, because it holds no location grant at all any more. One
/// grant, one asker.
///
/// Lives in the helper target rather than the package for that reason: the
/// package is linked into the app and the widget extension too, and a
/// prompt-triggering call sitting in shared code is the easiest way to
/// re-introduce the second prompt this whole design exists to prevent.
/// `SingleLocationPromptTests` enforces that.
///
/// THE PROMPT IS ONE SHOT. CoreLocation refuses to re-prompt once answered
/// and the locationd record cannot be cleared (tccutil fails -10814), so a
/// refusal is permanent as far as this app is concerned. That asymmetry is
/// why the app gates this behind its own re-askable explanation rather than
/// calling it on launch.
///
/// The waiting itself is `LocationAuthorizationWatcher`'s, in the shared
/// package (bluegull-aqi-hib.13). It used to be duplicated here -- twice,
/// once for asking and once for observing -- and the observing copy shipped
/// the very `.notDetermined` race the app-side copy had already been fixed
/// for. Asking and observing now differ in exactly the two places they
/// must: whether authorization is requested, and whether a `.notDetermined`
/// callback counts as the answer.
final class LocationAuthorizationRequester: NSObject, @unchecked Sendable {
    /// How long to hold the launchd transaction open waiting for an answer.
    ///
    /// This is in direct tension with pressured exit everywhere else in
    /// this process, and is deliberate rather than incidental: the hib.10
    /// probe held no transaction at all and survived only because the
    /// answer came in 5.4 seconds. A real person reading a dialog may take
    /// a minute; someone who walks away may take forever, which is what the
    /// bound is for. Two minutes is long enough that nobody actually
    /// answering loses, and short enough that an abandoned prompt doesn't
    /// pin a background process open indefinitely.
    static let decisionTimeout: TimeInterval = 120

    /// False when this instance is OBSERVING rather than asking.
    private let asking: Bool

    /// Created on the MAIN queue in `resolve()`, never before -- see that
    /// method for why that is load-bearing. Optional only because it cannot
    /// exist until that hop happens; written once, then only read.
    private var manager: CLLocationManager?
    private let log: Logger
    private let watcher: LocationAuthorizationWatcher

    init(
        log: Logger,
        timeout: TimeInterval = LocationAuthorizationRequester.decisionTimeout,
        asking: Bool = true
    ) {
        self.log = log
        self.asking = asking
        // The one behavioural difference, expressed once: while a prompt is
        // on screen `.notDetermined` means "not answered yet", whereas to
        // an observer it is a real and final answer.
        watcher = LocationAuthorizationWatcher(timeout: timeout, resolvesOnNotDetermined: !asking)
        super.init()
    }

    /// Puts the system prompt on screen and waits for the answer. Never
    /// throws and never hangs: every path out resolves, because the caller
    /// has a transaction to end and an XPC reply to send whatever the user
    /// did.
    func requestAuthorization() async -> LocationHelperAuthorization {
        await resolve()
    }

    /// The helper's CURRENT grant, without asking for one -- what every
    /// ordinary wake records, so a grant revoked in System Settings shows
    /// up on the next wake instead of never.
    static func settledAuthorization(log: Logger) async -> LocationHelperAuthorization {
        await LocationAuthorizationRequester(
            log: log,
            timeout: LocationAuthorizationWatcher.defaultTimeout,
            asking: false
        ).resolve()
    }

    /// EVERYTHING CORELOCATION TOUCHES HAPPENS ON THE MAIN QUEUE, and that
    /// is load-bearing rather than tidy. `CLLocationManager` delivers its
    /// delegate callbacks on the run loop of the thread that CREATED it,
    /// and this is reached from a `Task` spun off the XPC handler -- a
    /// dispatch thread with no run loop. MEASURED on the first live run,
    /// 2026-09-01: the prompt was approved, no callback ever arrived, the
    /// 120s deadline elapsed, and only its fallback read reported the
    /// grant. It "worked" 128 seconds late, which in the UI is a two-minute
    /// spinner in front of someone who already answered.
    ///
    /// `requestWhenInUseAuthorization()` is called UNCONDITIONALLY when
    /// asking, rather than behind a status check. It is a documented no-op
    /// once the user has answered, and installing the delegate provokes a
    /// callback carrying the real status either way -- so an
    /// already-decided process resolves in milliseconds. The status check
    /// this replaced read `authorizationStatus` synchronously right after
    /// constructing the manager, which is exactly the race
    /// `LocationAuthorizationWatcher` exists to close.
    private func resolve() async -> LocationHelperAuthorization {
        await MainActor.run {
            let manager = CLLocationManager()
            self.manager = manager
            // Installing the delegate is itself the trigger for the first
            // callback, so the request below has to come after it and
            // before anything awaits.
            self.watcher.install(on: manager)
            guard self.asking else { return }
            self.log.notice("AUTH_REQUESTING at=\(stamp(), privacy: .public) -- prompt should appear now")
            manager.requestWhenInUseAuthorization()
        }

        let status = await watcher.settledStatus(fallingBackTo: { [weak self] in
            // Read only if the deadline won -- i.e. nothing ever called
            // back at all.
            self?.manager?.authorizationStatus ?? .notDetermined
        })
        let authorization = Self.map(status)
        log.notice("""
        AUTH_SETTLED status=\(authorization.rawValue, privacy: .public) \
        asking=\(self.asking, privacy: .public) at=\(stamp(), privacy: .public)
        """)
        return authorization
    }

    /// Whether Location Services is on for the whole machine
    /// (bluegull-aqi-hib.18) -- a different question from this bundle's own
    /// grant, and one the app cannot ask for itself.
    ///
    /// Deliberately NOT called on the main actor. Apple documents this as
    /// potentially blocking, and blocking main in a process that is holding
    /// a launchd transaction is how a background agent becomes a beachball
    /// somebody else has to explain.
    static func locationServicesEnabled() -> Bool {
        CLLocationManager.locationServicesEnabled()
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
