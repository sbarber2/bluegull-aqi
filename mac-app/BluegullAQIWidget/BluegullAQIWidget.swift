import WidgetKit
import SwiftUI
import BluegullAQIKit

struct BluegullAQIWidgetEntry: TimelineEntry {
    let date: Date
    let reading: AQIReading?

    // The location this widget instance is configured for -- nil for
    // "current location" (see `LocationOptionEntity`'s own doc comment).
    // Carried on the entry (not just used to compute `reading`) so the
    // `widgetURL` tap target (bluegull-aqi-mtm.14) can encode the same
    // location the widget is actually showing.
    let configuredLocation: Location?

    init(date: Date, reading: AQIReading?, configuredLocation: Location? = nil) {
        self.date = date
        self.reading = reading
        self.configuredLocation = configuredLocation
    }

    init(_ snapshot: WidgetTimelineSnapshot, configuredLocation: Location? = nil) {
        date = snapshot.date
        reading = snapshot.reading
        self.configuredLocation = configuredLocation
    }
}

/// Thin `AppIntentTimelineProvider` glue -- the actual cache-reading/
/// reload-policy logic lives in `BluegullAQIKit.WidgetTimelineComputer`
/// (bluegull-aqi-mtm.2), specifically so it's unit-testable at all (an
/// `app-extension` target can't be linked against by a separate test
/// target -- see that type's doc comment). Never fetches network or
/// location itself (doc/DESIGN.md "Widget extension (WidgetKit)").
///
/// `AppIntentTimelineProvider`, not plain `TimelineProvider`, as of
/// bluegull-aqi-mtm.3 -- each widget instance's configured
/// `SelectLocationIntent` says which location it shows.
struct BluegullAQIWidgetTimelineProvider: AppIntentTimelineProvider {
    private let computer: WidgetTimelineComputer?

    init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        // The App Group suite couldn't be opened -- rather than crash
        // (widget extension crashes are disruptive system-wide, unlike a
        // container-app failure), degrade to "no data to show," the same
        // state as a genuine cache miss.
        computer = store.map(WidgetTimelineComputer.init(store:))
    }

    func placeholder(in context: Context) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: Date(), reading: nil)
    }

    func snapshot(for configuration: SelectLocationIntent, in context: Context) async -> BluegullAQIWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectLocationIntent, in context: Context) async -> Timeline<BluegullAQIWidgetEntry> {
        let now = Date()
        let nextReload = computer?.nextReloadDate(after: now) ?? now.addingTimeInterval(RefreshScheduler.defaultInterval)
        return Timeline(entries: [entry(for: configuration, now: now)], policy: .after(nextReload))
    }

    private func entry(for configuration: SelectLocationIntent, now: Date = Date()) -> BluegullAQIWidgetEntry {
        // configuration.location is nil for a not-yet-configured instance;
        // .location on the entity itself is nil for the "current location"
        // option specifically (see LocationOptionEntity's own doc
        // comment). Both collapse to the same nil, which
        // currentSnapshot(for:) already treats as "fall back to whatever
        // was most recently cached."
        let configuredLocation = configuration.location?.location
        guard let computer else {
            return BluegullAQIWidgetEntry(date: now, reading: nil, configuredLocation: configuredLocation)
        }
        return BluegullAQIWidgetEntry(
            computer.currentSnapshot(for: configuredLocation, now: now),
            configuredLocation: configuredLocation
        )
    }
}

struct BluegullAQIWidget: Widget {
    let kind = "BluegullAQIWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectLocationIntent.self, provider: BluegullAQIWidgetTimelineProvider()) { entry in
            // The whole widget is a tap target, deep-linking into the
            // container app's detail view (bluegull-aqi-mtm.14) -- same
            // pattern Apple's own Weather widget uses (doc/DESIGN.md
            // "Widget extension (WidgetKit)").
            BluegullAQIWidgetView(entry: entry)
                .widgetURL(WidgetDeepLink.url(for: entry.configuredLocation))
        }
        .configurationDisplayName(NowCastCopy.headline)
        .description("Local air quality at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
