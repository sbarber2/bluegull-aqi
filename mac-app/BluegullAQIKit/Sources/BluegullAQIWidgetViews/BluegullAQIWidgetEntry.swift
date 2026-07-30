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

    public init(date: Date, reading: AQIReading?, configuredLocation: Location? = nil) {
        self.date = date
        self.reading = reading
        self.configuredLocation = configuredLocation
    }

    public init(_ snapshot: WidgetTimelineSnapshot, configuredLocation: Location? = nil) {
        date = snapshot.date
        reading = snapshot.reading
        self.configuredLocation = configuredLocation
    }
}
