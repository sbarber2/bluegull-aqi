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

    // See WidgetTimelineSnapshot's own doc comment (bluegull-aqi-dc2.1) --
    // survives `reading` going nil once its own cache entry expires, so the
    // widget's empty state can say "last updated X ago" instead of an
    // unqualified "No Data."
    public let lastSuccessfulFetchDate: Date?

    public init(
        date: Date,
        reading: AQIReading?,
        configuredLocation: Location? = nil,
        lastSuccessfulFetchDate: Date? = nil
    ) {
        self.date = date
        self.reading = reading
        self.configuredLocation = configuredLocation
        self.lastSuccessfulFetchDate = lastSuccessfulFetchDate
    }

    public init(_ snapshot: WidgetTimelineSnapshot, configuredLocation: Location? = nil) {
        date = snapshot.date
        reading = snapshot.reading
        self.configuredLocation = configuredLocation
        lastSuccessfulFetchDate = snapshot.lastSuccessfulFetchDate
    }
}
