import WidgetKit
import SwiftUI
import BluegullAQIKit
import BluegullAQIWidgetViews

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
    private let requestedLocations: WidgetRequestedLocationsStore

    init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        // The App Group suite couldn't be opened -- rather than crash
        // (widget extension crashes are disruptive system-wide, unlike a
        // container-app failure), degrade to "no data to show," the same
        // state as a genuine cache miss.
        computer = store.map(WidgetTimelineComputer.init(store:))
        requestedLocations = WidgetRequestedLocationsStore(store: store)
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
        // Relays this instance's configured location to the container app
        // (bluegull-aqi-o4b) -- see WidgetRequestedLocationsStore's own doc
        // comment for why this, and not WidgetCenter, is what
        // AQIRefreshController actually reads. Every entry computation
        // re-records it (not just placement), which is what lets a removed
        // widget's entry naturally age out instead of needing an explicit
        // removal signal that doesn't exist.
        requestedLocations.recordSeen(configuredLocation, now: now)
        // .name is already the right display string either way --
        // "Current Location" for the explicit synthetic option, or the
        // pinned location's own label. A not-yet-configured instance
        // (configuration.location entirely nil, not just .location.location)
        // has no name to draw on yet, so this falls back to the same
        // synthetic name (bluegull-aqi-mtm.20).
        let locationName = configuration.location?.name ?? LocationOptionEntity.currentLocation.name
        guard let computer else {
            return BluegullAQIWidgetEntry(date: now, reading: nil, configuredLocation: configuredLocation, locationName: locationName)
        }
        return BluegullAQIWidgetEntry(
            computer.currentSnapshot(for: configuredLocation, now: now),
            configuredLocation: configuredLocation,
            locationName: locationName
        )
    }
}

struct BluegullAQIWidget: Widget {
    let kind = BluegullWidgetKind.aqi

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
        // Not "Local air quality" (bluegull-aqi-mtm.20) -- that implies
        // wherever-you-are, which stopped being true once each widget
        // instance can be pinned to a location you aren't at.
        .description("Air quality at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
