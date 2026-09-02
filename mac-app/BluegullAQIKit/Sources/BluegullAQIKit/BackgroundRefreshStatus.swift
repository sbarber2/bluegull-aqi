import Foundation

/// The helper agent's registration state, as the CONTAINER APP last observed
/// it (bluegull-aqi-hib.7).
///
/// Mirrors the cases of `SMAppService.Status` plus one the framework has no
/// opinion about (`unreachable`). It exists as its own type, written into
/// the App Group, because `SMAppService` is not available to the widget
/// extension -- app extensions cannot spawn or manage services -- so the
/// widget has no way to ask this question itself. The app asks and writes
/// down the answer; the widget reads it. Without that, the two surfaces
/// could disagree about whether background refresh is working, which is
/// exactly what this issue exists to prevent.
public enum LocationHelperAvailability: String, Sendable, Equatable, Codable {
    /// Registered and approved. Says nothing about whether it has a
    /// location grant -- that is `LocationHelperState.authorization`.
    case enabled
    /// Registered, but macOS defaults new background items to off pending
    /// explicit user approval. The agent never runs and nothing says why.
    case requiresApproval
    /// Never registered, or switched off by the user in Login Items &
    /// Extensions. The framework reports the same status for both, which is
    /// why `BackgroundRefreshStatus` needs a second signal to tell a fresh
    /// install from a deliberate switch-off.
    case notRegistered
    /// The plist or executable is missing -- a damaged or partial install.
    case notFound
    /// Registered and enabled, yet a poke got no answer at all. Distinct
    /// from every status above because the framework believes everything is
    /// fine, so only an actual attempt reveals it.
    case unreachable
}

/// What to tell the user about background refresh, derived from every
/// signal available (bluegull-aqi-hib.7).
///
/// Derived in one place, in the shared package, on purpose. The app and the
/// widget run in different processes and neither can see the other's state;
/// if each decided independently what "working" meant, they would eventually
/// disagree, and "one feature, two answers" is the exact failure this issue
/// and hib.6's Option 1 decision were both taken to avoid.
///
/// This is a status, not an error. Under hib.6 the app has no location
/// fallback by design, so every case here means Current Location genuinely
/// cannot refresh -- but pinned locations keep working throughout, since
/// they need no location grant at all (`CLGeocoder` needs network access,
/// not authorization -- confirmed live, bluegull-aqi-hib.12). The copy
/// below says so where it matters, so the product reads as degraded by one
/// feature rather than broken.
public enum BackgroundRefreshStatus: String, Sendable, Equatable, CaseIterable, Codable {
    /// Registered, approved, and holding a location grant.
    case working
    /// Never set up. A fresh install that hasn't been through hib.6's
    /// first run, or one where the user chose "Not now".
    case neverSetUp
    /// Set up once and since switched off in Login Items & Extensions.
    /// There is NO notification when that happens, which is why this is
    /// detected by polling and corroborated by whether the helper has ever
    /// recorded state.
    case turnedOff
    /// Registered but awaiting approval in System Settings.
    case needsApproval
    /// Running, but it has no location grant and has not been asked yet.
    case permissionNotGranted
    /// The user answered "Don't Allow". Unrecoverable by us: CoreLocation
    /// refuses to re-prompt once answered and the locationd record cannot
    /// be cleared (tccutil fails -10814). System Settings is the only path.
    case permissionRefused
    /// A damaged install -- the agent's plist or executable is missing.
    case bundleMissing
    /// Registered and enabled, but not answering.
    case unreachable
    /// Registered, approved, holding a grant -- and demonstrably not
    /// running anyway.
    ///
    /// MEASURED 2026-09-02, and the reason this case exists: an agent whose
    /// Background Task Management record pins a lightweight code
    /// requirement the current executable no longer satisfies fails to
    /// spawn with EX_CONFIG, and launchd retries every 10 seconds forever
    /// -- 3,452 attempts in twelve hours on a real machine. Throughout,
    /// `SMAppService.status` reports `.enabled`, so every signal this type
    /// otherwise has says everything is fine.
    ///
    /// The only observable difference is that the helper stops writing. So
    /// that is what this checks -- exactly the corroboration
    /// bluegull-aqi-hib.7 anticipated ("worth also treating a long gap
    /// since the last successful helper write as corroborating evidence").
    case notWaking

    /// The single decision point. `helperState` is nil until the helper has
    /// run at least once, which is what distinguishes "never set up" from
    /// "was set up and has since been switched off" -- `SMAppService`
    /// reports `.notRegistered` for both.
    /// How long the helper may go without writing before its silence is
    /// treated as evidence it isn't running.
    ///
    /// Deliberately far beyond any legitimate gap. The agent wakes every 30
    /// minutes with a 15-minute grace period, so ~45 minutes is the honest
    /// worst case; six hours leaves room for a machine that slept, which is
    /// the one benign way this can look bad. A false alarm on a working
    /// install is worse than a beat of silence, and this self-corrects on
    /// the helper's next wake either way. Past six hours the
    /// current-location entry is also long dead (3h hard TTL), so there is
    /// nothing to show regardless and saying why is strictly better than
    /// an unexplained blank.
    public static let silenceImpliesNotWaking: TimeInterval = 6 * 3600

    public static func derive(
        availability: LocationHelperAvailability?,
        helperState: LocationHelperState?,
        now: Date = Date()
    ) -> BackgroundRefreshStatus {
        // Nothing observed yet: the app hasn't polled since launch. Treat
        // as not-set-up rather than inventing a failure -- a wrong alarm on
        // a working install is worse than a beat of silence.
        guard let availability else { return helperState == nil ? .neverSetUp : .working }

        switch availability {
        case .requiresApproval:
            return .needsApproval
        case .notFound:
            return .bundleMissing
        case .notRegistered:
            return helperState == nil ? .neverSetUp : .turnedOff
        case .unreachable:
            return .unreachable
        case .enabled:
            guard let state = helperState else {
                // Registered and enabled but has not run yet -- the gap
                // between the app registering it and its first wake.
                // Nothing is wrong.
                return .working
            }
            switch state.authorization {
            case .refused:
                return .permissionRefused
            case .notDetermined:
                return .permissionNotGranted
            case .authorized:
                // Enabled and granted, but has it actually run lately?
                return now.timeIntervalSince(state.recordedAt) > silenceImpliesNotWaking
                    ? .notWaking
                    : .working
            }
        }
    }

    public var isWorking: Bool { self == .working }

    /// Short enough for a widget's empty state, which has room for one
    /// line. Deliberately describes the SITUATION, not the fix -- a widget
    /// has no buttons and cannot be tapped through to Settings, so telling
    /// someone to go somewhere from a surface that can't take them there
    /// just adds friction. The app carries the fix.
    public var widgetCaption: String? {
        switch self {
        case .working: nil
        case .neverSetUp: "Open BlueGull AQI to set up"
        case .turnedOff, .needsApproval, .bundleMissing, .unreachable: "Background updates are off"
        case .notWaking: "Background updates aren't running"
        case .permissionNotGranted, .permissionRefused: "Location access needed"
        }
    }

    /// Plain language, for the popover. Says what happened and why, not
    /// what went wrong internally -- nothing here mentions helpers, agents,
    /// launchd or XPC, which are all true and none of which is the user's
    /// problem.
    ///
    /// `afterUpgrade` changes the three states an upgrading user can
    /// actually land in (bluegull-aqi-hib.8). Being asked for location
    /// again, by a product you already granted location to, reads as either
    /// a bug or a land grab unless something explains it -- and the
    /// explanation is real: the old grant belongs to a different bundle
    /// identifier and genuinely cannot be reused. Saying "this update
    /// changed how it works" is the difference between a user who
    /// understands and one who assumes the app broke itself.
    public func explanation(afterUpgrade: Bool = false) -> String? {
        switch self {
        case .working:
            nil
        case .neverSetUp:
            afterUpgrade
                ? "This update moves air quality for your current location into a background updater, so it keeps working when BlueGull AQI isn't open. That updater needs your permission once -- it's separate from the location access you gave BlueGull before."
                : "BlueGull AQI isn't set up to check your location yet, so it can't show air quality for where you are."
        case .turnedOff:
            "Background updates were turned off in System Settings, so air quality for your current location has stopped refreshing."
        case .needsApproval:
            "macOS is waiting for you to approve BlueGull AQI's background updates. Until then, air quality for your current location won't refresh."
        case .permissionNotGranted:
            afterUpgrade
                ? "BlueGull AQI's new background updater still needs permission to use your location. It asks separately from the access you gave BlueGull before."
                : "BlueGull AQI needs permission to use your location before it can show air quality for where you are."
        case .permissionRefused:
            afterUpgrade
                ? "Location access was declined for BlueGull AQI's background updater, so air quality for your current location has stopped updating. macOS only asks once, so this has to be turned back on in System Settings."
                : "Location access is turned off for BlueGull AQI. macOS only asks once, so this has to be changed in System Settings."
        case .bundleMissing:
            "Part of BlueGull AQI seems to be missing. Reinstalling should fix it."
        case .unreachable:
            "BlueGull AQI's background updater isn't responding. Quitting and reopening BlueGull AQI usually fixes it."
        case .notWaking:
            "BlueGull AQI's background updater hasn't run in a while, so air quality for your current location has stopped refreshing. Turning it off and on again should fix it."
        }
    }

    /// Always paired with `explanation` where one exists: this issue's
    /// acceptance criteria require a working path back, not just an
    /// accurate diagnosis.
    public var recovery: Recovery {
        switch self {
        case .working: .none
        case .neverSetUp, .turnedOff: .turnOnInApp
        case .needsApproval: .loginItemsSettings
        case .permissionNotGranted: .turnOnInApp
        case .permissionRefused: .locationPrivacySettings
        case .bundleMissing, .unreachable: .none
        // Re-registering is exactly the repair: it rebuilds the launchd
        // record against the executable that actually exists now.
        case .notWaking: .turnOnInApp
        }
    }

    /// Reassurance that the rest of the app is fine, shown alongside the
    /// explanation. Pinned locations need no location grant at all
    /// (confirmed live, bluegull-aqi-hib.12), so every case here degrades
    /// the product by one feature rather than breaking it -- and saying so
    /// is the difference between "this is broken" and "this one thing needs
    /// attention."
    public static let pinnedLocationsUnaffected =
        "Locations you've added by name still work normally."

    public enum Recovery: Sendable, Equatable {
        case none
        /// Our own re-askable setup flow (bluegull-aqi-hib.6).
        case turnOnInApp
        case loginItemsSettings
        case locationPrivacySettings

        public var buttonTitle: String? {
            switch self {
            case .none: nil
            case .turnOnInApp: "Turn On Background Updates"
            case .loginItemsSettings: "Open Login Items Settings"
            case .locationPrivacySettings: "Open Location Settings"
            }
        }

        /// The System Settings pane to open, for the cases we can't fix
        /// ourselves. Kept here rather than at the call site so the app and
        /// any later surface send the user to the same place.
        public var settingsURL: URL? {
            switch self {
            case .none, .turnOnInApp:
                nil
            case .loginItemsSettings:
                URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            case .locationPrivacySettings:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            }
        }
    }
}
