import Observation
import ServiceManagement
import SwiftUI
import BluegullAQIKit

/// Drives bluegull-aqi-hib.6's first run: our own re-askable explanation,
/// then -- only if the user says yes -- registering the helper and having it
/// ask for the one-shot system grant.
///
/// THE ASYMMETRY THIS EXISTS FOR. The system location prompt is one shot and
/// unrecoverable by us: CoreLocation refuses to re-prompt once answered, and
/// the locationd record cannot be cleared (tccutil fails -10814). Under
/// hib.6's Option 1 the app has no location grant of its own to fall back
/// on, so a "Don't Allow" kills Current Location outright. That makes asking
/// at a badly-understood moment far more expensive than asking slightly
/// later -- hence a pre-prompt we control, which costs nothing when
/// declined, in front of a system prompt that can only be spent once.
///
/// Deliberately a thin orchestration layer over `LocationHelperController`,
/// not unit tested itself -- same reasoning as `AQIRefreshController`. What
/// it orchestrates either succeeds or fails inside SMAppService, launchd and
/// CoreLocation, none of which a test can stand in for; bluegull-aqi-hib.9
/// covers this half by observation.
@Observable
@MainActor
final class LocationSetupCoordinator {
    /// Where the first-run flow currently is. `waitingForPermission` is
    /// deliberately a determinate state with a deadline behind it rather
    /// than an open-ended spinner -- the helper's own decision timeout is
    /// 120s, and a UI that can hang forever waiting on a dialog the user
    /// may have dismissed is worse than one that admits it gave up.
    enum Phase: Equatable {
        case explaining
        case registering
        case waitingForPermission
        case granted
        /// The user answered "Don't Allow", or an administrator forbids it.
        /// Unrecoverable by us; System Settings is the only path left.
        case refused
        /// The prompt was never answered, or the helper never replied. Not
        /// a refusal -- nothing was spent, and asking again still works.
        case unanswered
        /// Registration itself failed, or the helper could not be reached.
        case failed(String)
    }

    private(set) var phase: Phase = .explaining

    /// `phase:` exists for render tests, which need to see states that can
    /// only be reached for real by spending the one-shot system prompt.
    /// Deliberately an initializer rather than relaxing `phase`'s setter:
    /// `@Observable`'s macro expansion happens to leave a `private(set)`
    /// property assignable from a `@testable` import, which is an accident
    /// of the expansion and not something to build on.
    init(phase: Phase = .explaining) {
        self.phase = phase
    }

    /// Set when the user picks "Not now". Persisted, because the whole point
    /// of the pre-prompt is that declining it is free and repeatable -- so
    /// the app must stop opening this window at every launch while still
    /// offering the choice from the popover indefinitely.
    ///
    /// Plain `UserDefaults`, not `@AppStorage`: that is a `DynamicProperty`
    /// and only does anything useful inside a `View`'s update cycle. Here it
    /// would silently be an ordinary property that happens to read the right
    /// value -- container-app-only is correct for it, since nothing outside
    /// this process has any use for the answer.
    @ObservationIgnored
    private var declined: Bool {
        get { UserDefaults.standard.bool(forKey: Self.declinedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.declinedKey) }
    }

    private static let declinedKey = "locationSetupDeclined"

    static var isHelperEnabled: Bool { LocationHelperController.status == .enabled }

    /// True when the app should open the setup window by itself. Once the
    /// agent is enabled there is nothing to ask, and once the user has said
    /// "Not now" we stop volunteering -- the popover keeps the offer alive.
    ///
    /// Deliberately does NOT consult a "have we shown this before" flag. The
    /// registration state IS the answer, so there is no second piece of
    /// state that could drift out of agreement with it -- the same reasoning
    /// `LaunchAtLoginToggle` already applies to `SMAppService.mainApp`.
    var shouldOfferSetupOnLaunch: Bool {
        !Self.isHelperEnabled && !declined
    }

    /// Whether the popover should keep offering to turn this on. Unlike the
    /// launch-time offer, this ignores "Not now" -- declining must be free
    /// AND reversible, so the affordance never goes away while the helper is
    /// off.
    static var shouldOfferSetupInPopover: Bool { !isHelperEnabled }

    /// The user said yes to OUR explanation. Everything past this point can
    /// spend the system prompt.
    func enable() async {
        declined = false
        phase = .registering

        if case .failure(let error) = LocationHelperController.register() {
            phase = .failed(Self.describe(registrationError: error))
            return
        }

        // Registration alone does not start the agent -- measured runs=0
        // immediately after a successful register(), which is correct for a
        // job with no RunAtLoad. Poking it is what makes the prompt arrive
        // while the user is still looking at the window that just asked,
        // rather than at whatever moment the system's own schedule picks.
        phase = .waitingForPermission
        guard let response = await LocationHelperController.requestAuthorization() else {
            phase = .failed(
                "BlueGull couldn't start its background updater. Try quitting and reopening BlueGull AQI."
            )
            return
        }

        switch response.authorization {
        case .authorized: phase = .granted
        case .refused: phase = .refused
        case .notDetermined: phase = .unanswered
        }
    }

    /// The user said "Not now" to OUR explanation -- no system prompt was
    /// consumed, so this costs nothing and can be undone from the popover at
    /// any time.
    func declineForNow() {
        declined = true
        phase = .explaining
    }

    /// `.requiresApproval` is its own trap: registration succeeded, but
    /// macOS defaults new background items to disabled pending explicit user
    /// approval, so the agent never runs and nothing says why.
    var needsSystemSettingsApproval: Bool {
        LocationHelperController.status == .requiresApproval
    }

    private static func describe(registrationError error: Error) -> String {
        let ns = error as NSError
        return "BlueGull couldn't set up background updates (\(ns.domain) \(ns.code))."
    }
}
