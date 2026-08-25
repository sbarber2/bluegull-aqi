import WidgetKit
import SwiftUI
import BluegullAQIKit
import BluegullAQIWidgetViews

/// Thin `AppIntentTimelineProvider` glue -- the actual cache-reading/
/// reload-policy logic lives in `BluegullAQIKit.WidgetTimelineComputer`
/// (bluegull-aqi-mtm.2), specifically so it's unit-testable at all (an
/// `app-extension` target can't be linked against by a separate test
/// target -- see that type's doc comment).
///
/// Fetches the network itself on a cache miss, as of bluegull-aqi-mtm.24 --
/// it no longer depends on the container app to do that for it. Still does
/// NOT resolve location itself (no location entitlement): "Current
/// Location" widgets read whatever GPS the container app last resolved.
///
/// `AppIntentTimelineProvider`, not plain `TimelineProvider`, as of
/// bluegull-aqi-mtm.3 -- each widget instance's configured
/// `SelectLocationIntent` says which location it shows.
struct BluegullAQIWidgetTimelineProvider: AppIntentTimelineProvider {
    private let computer: WidgetTimelineComputer?
    // nil for the same App-Group-unavailable reason as `computer` above --
    // there'd be nowhere to write a result, so there's no point fetching one.
    private let coordinator: AQIFetchCoordinator?
    // bluegull-aqi-e70.27: reverse-geocodes a Current Location widget's
    // resolved coordinate into the same `locationName` caption slot the
    // widget face already renders. Same "network only, no location
    // entitlement needed" reasoning as the fetch above -- CLGeocoder's
    // reverse lookup doesn't touch CLLocationManager/authorization at all.
    private let locationResolver: LocationResolver

    init(store: SharedCacheStore? = UserDefaultsCacheStore(), locationResolver: LocationResolver = LocationResolver()) {
        // The App Group suite couldn't be opened -- rather than crash
        // (widget extension crashes are disruptive system-wide, unlike a
        // container-app failure), degrade to "no data to show," the same
        // state as a genuine cache miss.
        computer = store.map(WidgetTimelineComputer.init(store:))
        coordinator = store.map { AQIFetchCoordinator(cache: AppGroupCache(store: $0)) }
        self.locationResolver = locationResolver
    }

    func placeholder(in context: Context) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: Date(), reading: nil)
    }

    func snapshot(for configuration: SelectLocationIntent, in context: Context) async -> BluegullAQIWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectLocationIntent, in context: Context) async -> Timeline<BluegullAQIWidgetEntry> {
        var now = Date()
        var resolved = entry(for: configuration, now: now)

        // Fetch right here, in this process, on a cache miss OR a merely
        // soft-stale reading for a specifically-pinned location (bluegull-
        // aqi-mtm.23/mtm.24) -- rather than rendering "Data Unavailable" and
        // waiting for the container app to notice and fetch on our behalf,
        // which measured 3-5 minutes end-to-end (bluegull-aqi-mtm.22) versus
        // 0.343s for this path on a real user-configured location. WidgetKit
        // hands this provider the correct configuration promptly; it was
        // only ever the *acting* on it that had to round-trip through
        // another process.
        //
        // `freshness == .stale`, not just `reading == nil`, per
        // `AQIFreshness.stale`'s own doc comment ("worth refetching to
        // replace") -- found live, 2026-08-24: `AppGroupCache.get()`
        // deliberately keeps returning a reading for the entire soft-to-hard
        // window (up to 3 hours), so a `reading == nil`-only guard meant a
        // pinned widget effectively only ever refetched once every ~3 hours
        // (at hard expiry), not once it went stale past the 1-hour soft TTL
        // the rest of the freshness system assumes -- two real pinned
        // widgets (East Lansing, Marlton) both sat `.stale` for ~2 hours
        // before this fix, never refetching in between despite WidgetKit
        // calling this provider again in the meantime.
        //
        // Deliberately NOT done for a nil configured location ("Current
        // Location"): resolving GPS needs a location entitlement this
        // extension still doesn't have, so those keep reading whatever the
        // container app last resolved.
        //
        // Failure is silent by design -- `resolved` simply stays as the
        // cache produced it, which is the same empty/stale state this
        // returned before any of this existed. A widget is the wrong
        // surface for an error dialog, and the menu bar popover already
        // surfaces fetch errors properly (bluegull-aqi-e70.24).
        if (resolved.reading == nil || resolved.freshness == .stale),
           let pinned = configuration.location?.location,
           let coordinator {
            _ = try? await coordinator.fetch(location: pinned, mode: DataSourceModeStore.currentMode())
            now = Date()
            resolved = entry(for: configuration, now: now)
        }

        // bluegull-aqi-e70.27: only for Current Location (a pinned
        // location's `locationName` is already the user's own chosen
        // label, nothing to resolve) -- attaches the reverse-geocoded
        // place name alongside the existing "Current Location" caption,
        // not in place of it. `configuration.location == nil` (the outer
        // optional) is NOT the right check here: a widget explicitly
        // configured to Current Location has a real, non-nil
        // `LocationOptionEntity` whose *own* `.location` property is nil
        // (see `entry(for:)`'s `configuredLocation` derivation just above,
        // which already unwraps both levels correctly) -- checking the
        // outer optional alone missed every already-configured Current
        // Location widget and only ever matched a brand new,
        // not-yet-configured instance. Silent failure by design, same
        // reasoning as the fetch above: `resolved` just has no resolved
        // place name if reverse geocoding has no network/no result.
        if configuration.location?.location == nil, let reading = resolved.reading,
           let placeName = try? await locationResolver.placeName(for: reading.location) {
            resolved = resolved.withResolvedPlaceName(placeName)
        }

        let nextReload = computer?.nextReloadDate(after: now) ?? now.addingTimeInterval(RefreshScheduler.defaultInterval)
        return Timeline(entries: [resolved], policy: .after(nextReload))
    }

    private func entry(for configuration: SelectLocationIntent, now: Date = Date()) -> BluegullAQIWidgetEntry {
        // configuration.location is nil for a not-yet-configured instance;
        // .location on the entity itself is nil for the "current location"
        // option specifically (see LocationOptionEntity's own doc
        // comment). Both collapse to the same nil, which
        // currentSnapshot(for:) already treats as "fall back to whatever
        // was most recently cached."
        let configuredLocation = configuration.location?.location
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
