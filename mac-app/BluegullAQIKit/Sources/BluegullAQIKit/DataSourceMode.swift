import Foundation

/// Which client fetches AQI data (bluegull-aqi-e70.3, doc/DESIGN.md "Data
/// flow / mode selection"): `service` calls the BlueGull backend Lambda
/// using its own key; `direct` calls AirNow directly using the user's own
/// Keychain-stored key (`AirNowAPIKeyStore`).
public enum DataSourceMode: String, Sendable, Equatable, CaseIterable {
    case service
    case direct
}

/// UserDefaults-key/default-value constants for persisting the user's
/// choice -- kept here, not duplicated at each call site, so the settings
/// toggle (bluegull-aqi-e70.3) and everything that reads this to decide
/// which client to call never risk disagreeing on the key string or the
/// default.
///
/// Stored in the **App Group** suite, not `UserDefaults.standard`
/// (bluegull-aqi-mtm.24). This was container-app-only, on the reasoning
/// that "the widget extension never fetches data itself" -- which stopped
/// being true in bluegull-aqi-mtm.23: the widget now fetches on a cache
/// miss, so it has to know which mode the user picked. A mirror (the
/// `SharedMenuBarLocationStore` pattern) would have worked, but the mode
/// selects which *client* runs, so a stale mirror means fetching the wrong
/// way entirely -- one shared location is the safer shape.
public enum DataSourceModeStore {
    public static let userDefaultsKey = "dataSourceMode"

    /// The App Group suite both processes read and write. nil only if the
    /// suite can't be opened -- same graceful degradation as
    /// `UserDefaultsCacheStore`; callers fall back to `defaultMode`.
    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: UserDefaultsCacheStore.appGroupIdentifier)
    }

    /// The user's current selection, or `defaultMode` if unset/unreadable.
    /// The single read path for both the container app and the widget.
    public static func currentMode(in defaults: UserDefaults? = sharedDefaults) -> DataSourceMode {
        guard let raw = defaults?.string(forKey: userDefaultsKey),
              let mode = DataSourceMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    /// One-time move of a pre-existing selection out of the container app's
    /// own `UserDefaults.standard`, where this used to live. Without it, a
    /// user who had explicitly chosen Direct mode would silently revert to
    /// the Service default on first launch after updating. No-op once the
    /// App Group copy exists, and no-op if there was never a stored choice.
    public static func migrateFromStandardIfNeeded(
        standard: UserDefaults = .standard,
        shared: UserDefaults? = sharedDefaults
    ) {
        guard let shared, shared.string(forKey: userDefaultsKey) == nil else { return }
        guard let legacy = standard.string(forKey: userDefaultsKey),
              DataSourceMode(rawValue: legacy) != nil else { return }
        shared.set(legacy, forKey: userDefaultsKey)
        standard.removeObject(forKey: userDefaultsKey)
    }

    /// Service mode is the default for a fresh install: works immediately
    /// with zero setup, no AirNow key needed (bluegull-aqi-8ef.2, DECIDED
    /// 2026-07-30).
    public static let defaultMode: DataSourceMode = .service
}
