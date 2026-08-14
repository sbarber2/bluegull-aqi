import Foundation

/// Dev/testing-only override for `BluegullServiceClient`'s backend base URL
/// (bluegull-aqi-e70.28) -- lets Steve point Service mode at a local server
/// or a different deployed stack without editing and rebuilding the
/// hardcoded constant in `BluegullServiceClient` each time.
///
/// Deliberately not a supported/shipping feature (DECIDED 2026-08-14): the
/// only UI that ever writes this key is a field hidden behind a secret
/// gesture in `SettingsView` (Option-click the "Settings" title) -- there's
/// no discoverable, ordinary-user path to pointing the app at an arbitrary
/// server. `resolvedBaseURL` still has to be defensive about a garbage
/// stored value (e.g. leftover empty string, or a string that isn't a valid
/// URL) since nothing validates the field's contents before saving.
///
/// App Group-backed, same reasoning as `DataSourceModeStore`: the widget
/// extension fetches for itself now (bluegull-aqi-mtm.23), so it needs to
/// see the same override the container app's hidden field wrote, not a
/// stale mirror.
public enum DevServiceURLOverrideStore {
    public static let userDefaultsKey = "devServiceBaseURLOverride"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: UserDefaultsCacheStore.appGroupIdentifier)
    }

    /// `fallback` whenever there's nothing usable stored -- unset or empty.
    /// `URL(string:)` itself is lenient enough that almost any other
    /// non-empty text (including outright garbage) parses into *some* URL,
    /// so this can't validate much beyond "was anything typed at all" --
    /// the rest of the safety net here is that only the hidden dev field
    /// ever writes this key, not that this function can catch a typo.
    public static func resolvedBaseURL(fallback: URL, in defaults: UserDefaults?) -> URL {
        guard let raw = defaults?.string(forKey: userDefaultsKey), !raw.isEmpty,
              let url = URL(string: raw) else {
            return fallback
        }
        return url
    }
}
