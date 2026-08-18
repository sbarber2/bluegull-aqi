import WidgetKit
import BluegullAQIKit

/// Public so both the `BluegullAQIWidget` app-extension target (which
/// constructs these from `AppIntentTimelineProvider`) and test/harness
/// targets that can't link that app-extension (bluegull-aqi-mtm.10) can
/// use it. Lives alongside `BluegullAQIWidgetView` since the two are always
/// used together.
public struct BluegullAQIWidgetEntry: TimelineEntry {
    public let date: Date
    public let reading: AQIReading?

    // The location this widget instance is configured for -- nil for
    // "current location" (see `LocationOptionEntity`'s own doc comment).
    // Carried on the entry (not just used to compute `reading`) so the
    // `widgetURL` tap target (bluegull-aqi-mtm.14) can encode the same
    // location the widget is actually showing.
    public let configuredLocation: Location?

    // The same location's user-facing name (bluegull-aqi-mtm.20) -- a
    // pinned location's own label, or "Current Location" -- so every
    // widget face can show which location it's displaying instead of
    // leaving that ambiguous now that widgets aren't all showing the same
    // thing. Carried separately from `configuredLocation` since `Location`
    // itself is just coordinates, with no name of its own.
    public let locationName: String

    // See WidgetTimelineSnapshot's own doc comment (bluegull-aqi-dc2.1) --
    // survives `reading` going nil once its own cache entry expires, so the
    // widget's empty state can say "last updated X ago" instead of an
    // unqualified "No Data."
    public let lastSuccessfulFetchDate: Date?

    /// `reading`'s own freshness (bluegull-aqi-dc2.5) -- nil exactly when
    /// `reading` is nil. A `.stale` reading is still shown (that's the
    /// point: past the soft TTL but within the hard one, rather than going
    /// straight to the empty state), but the view marks it as aged rather
    /// than looking identical to a current value.
    public let freshness: AQIFreshness?

    /// Reverse-geocoded place name for a Current Location widget
    /// (bluegull-aqi-e70.27's widget-face follow-up) -- always nil for a
    /// pinned location (its `locationName` is already the user's own
    /// chosen label, nothing to resolve). Deliberately a SEPARATE field
    /// from `locationName`, not a swap-in replacement for it: Steve wanted
    /// "Current Location" to stay visible AND the resolved place shown
    /// alongside it, not one replacing the other -- there's room for both
    /// on all three widget sizes. nil until `BluegullAQIWidgetTimelineProvider`'s
    /// async reverse-geocode lookup completes (or if it fails/has no
    /// network); the view just omits the extra line in that case.
    public let resolvedPlaceName: String?

    public init(
        date: Date,
        reading: AQIReading?,
        configuredLocation: Location? = nil,
        locationName: String = LocationOptionEntity.currentLocation.name,
        lastSuccessfulFetchDate: Date? = nil,
        freshness: AQIFreshness? = nil,
        resolvedPlaceName: String? = nil
    ) {
        self.date = date
        self.reading = reading
        self.configuredLocation = configuredLocation
        self.locationName = locationName
        self.lastSuccessfulFetchDate = lastSuccessfulFetchDate
        self.freshness = freshness
        self.resolvedPlaceName = resolvedPlaceName
    }

    public init(_ snapshot: WidgetTimelineSnapshot, configuredLocation: Location? = nil, locationName: String = LocationOptionEntity.currentLocation.name) {
        date = snapshot.date
        reading = snapshot.reading
        self.configuredLocation = configuredLocation
        self.locationName = locationName
        lastSuccessfulFetchDate = snapshot.lastSuccessfulFetchDate
        freshness = snapshot.freshness
        resolvedPlaceName = nil
    }

    /// Same entry, `resolvedPlaceName` filled in -- `BluegullAQIWidgetTimelineProvider`
    /// (the app-extension's own thin `AppIntentTimelineProvider` glue, not
    /// unit-testable itself -- see that type's own doc comment) builds an
    /// entry synchronously first, then reverse-geocodes and attaches the
    /// resolved place name via this method once that async lookup completes.
    public func withResolvedPlaceName(_ resolvedPlaceName: String) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(
            date: date,
            reading: reading,
            configuredLocation: configuredLocation,
            locationName: locationName,
            lastSuccessfulFetchDate: lastSuccessfulFetchDate,
            freshness: freshness,
            resolvedPlaceName: resolvedPlaceName
        )
    }
}
