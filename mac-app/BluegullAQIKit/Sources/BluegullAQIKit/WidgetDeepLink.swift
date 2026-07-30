import Foundation

/// Encodes/decodes the `Location` a widget instance is showing into the
/// `widgetURL` used for its tap-to-expand deep link (bluegull-aqi-mtm.14) --
/// shared so the widget extension (which builds the URL) and the container
/// app (which parses it back on the receiving end) can't drift out of sync
/// on the scheme/host/query-parameter format.
public enum WidgetDeepLink {
    public static let scheme = "bluegullaqi"
    public static let host = "widget-detail"

    /// nil `location` encodes as a URL with no query items -- matches
    /// `WidgetTimelineComputer.currentSnapshot(for:)`'s own "nil means fall
    /// back to whatever was most recently cached" semantics, so a widget
    /// configured for "current location" deep-links to that same fallback
    /// behavior on the receiving end, rather than needing its own separate
    /// "current location" encoding.
    public static func url(for location: Location?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let location {
            components.queryItems = [
                URLQueryItem(name: "lat", value: String(location.latitude)),
                URLQueryItem(name: "lon", value: String(location.longitude)),
            ]
        }
        // scheme/host are compile-time-constant, valid literals with no
        // other components set -- URLComponents.url can only fail to
        // produce a URL from malformed/conflicting components, which isn't
        // possible here.
        return components.url!
    }

    /// Parses a URL built by `url(for:)`. Malformed or foreign input (a lat
    /// with no matching lon, non-numeric values, a URL from something else
    /// entirely) is treated the same as "no location supplied," not an
    /// error -- there's nothing actionable to show a user for a
    /// parse-failure state here, and falling back to "most recently
    /// cached" degrades gracefully either way.
    public static func location(from url: URL) -> Location? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let latString = queryItems.first(where: { $0.name == "lat" })?.value,
              let lonString = queryItems.first(where: { $0.name == "lon" })?.value,
              let latitude = Double(latString),
              let longitude = Double(lonString) else {
            return nil
        }
        return Location(latitude: latitude, longitude: longitude)
    }
}
