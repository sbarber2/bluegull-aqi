import Foundation

/// Per-data-source request timeout, user-configurable (bluegull-aqi-e70.43)
/// -- found via a real cold-start timeout against the Lambda backend:
/// "we've exceeded our client response timeout to the lambda on cold
/// starts on occasion." Two independent values, not one shared timeout:
/// Direct mode talks straight to AirNow and doesn't hit the Lambda
/// cold-start problem this exists for, so its own default is unchanged.
///
/// App Group-backed, same reasoning as `DataSourceModeStore`: the widget
/// extension fetches for itself now (bluegull-aqi-mtm.23), so both
/// `AirNowDirectClient` and `BluegullServiceClient` need to see whatever
/// Steve configures here regardless of which process is making the
/// request, not a stale per-process default.
public enum RequestTimeoutStore {
    public static let directUserDefaultsKey = "directModeRequestTimeout"
    public static let serviceUserDefaultsKey = "serviceModeRequestTimeout"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: UserDefaultsCacheStore.appGroupIdentifier)
    }

    /// Unchanged from `AirNowDirectClient`'s prior hardcoded value.
    public static let defaultDirectTimeout: TimeInterval = 10

    /// Bumped from 10s to 15s (bluegull-aqi-e70.43) -- the actual reported
    /// problem: occasional Lambda cold starts exceeding the old 10s budget.
    public static let defaultServiceTimeout: TimeInterval = 15

    /// Bounds for the Settings stepper, also enforced on read so a
    /// corrupted or hand-edited stored value can't produce a nonsensical
    /// (zero, negative, or unreasonably long) request timeout.
    public static let minimumTimeout: TimeInterval = 5
    public static let maximumTimeout: TimeInterval = 60

    public static func directTimeout(in defaults: UserDefaults? = sharedDefaults) -> TimeInterval {
        resolvedTimeout(key: directUserDefaultsKey, default: defaultDirectTimeout, in: defaults)
    }

    public static func serviceTimeout(in defaults: UserDefaults? = sharedDefaults) -> TimeInterval {
        resolvedTimeout(key: serviceUserDefaultsKey, default: defaultServiceTimeout, in: defaults)
    }

    private static func resolvedTimeout(key: String, default defaultValue: TimeInterval, in defaults: UserDefaults?) -> TimeInterval {
        guard let defaults, defaults.object(forKey: key) != nil else { return defaultValue }
        let stored = defaults.double(forKey: key)
        guard stored >= minimumTimeout, stored <= maximumTimeout else { return defaultValue }
        return stored
    }
}
