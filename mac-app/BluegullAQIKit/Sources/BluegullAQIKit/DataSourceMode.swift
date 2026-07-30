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
/// toggle (bluegull-aqi-e70.3) and whatever eventually reads this to decide
/// which client to call (bluegull-aqi-e70.6) never risk disagreeing on the
/// key string or the default. `UserDefaults.standard`, not the App Group:
/// this is a container-app-only setting -- the widget extension never
/// fetches data itself (doc/DESIGN.md "Widget extension (WidgetKit)"), so
/// it never needs to know which mode produced what's in the shared cache.
public enum DataSourceModeStore {
    public static let userDefaultsKey = "dataSourceMode"

    /// Service mode is the default for a fresh install: works immediately
    /// with zero setup, no AirNow key needed (bluegull-aqi-8ef.2, DECIDED
    /// 2026-07-30).
    public static let defaultMode: DataSourceMode = .service
}
