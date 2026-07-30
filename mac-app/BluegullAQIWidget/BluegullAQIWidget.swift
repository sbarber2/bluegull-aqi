import WidgetKit
import SwiftUI
import BluegullAQIKit

struct BluegullAQIWidgetEntry: TimelineEntry {
    let date: Date
    let reading: AQIReading?
}

/// Reads the App Group cache written by the container app; never fetches
/// network or location itself (bluegull-aqi-mtm.2, doc/DESIGN.md "Widget
/// extension (WidgetKit)").
///
/// Uses `AppGroupCache.mostRecentEntry()` rather than a specific configured
/// location -- there's no per-instance location configuration yet (that's
/// App Intents work, bluegull-aqi-mtm.3); once it lands, a configured
/// instance should look up its own pinned location instead of "whatever
/// was cached most recently."
struct BluegullAQIWidgetTimelineProvider: TimelineProvider {
    private let cache: AppGroupCache?
    private let refreshScheduler: RefreshScheduler?

    init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        if let store {
            cache = AppGroupCache(store: store)
            refreshScheduler = RefreshScheduler(store: store)
        } else {
            // The App Group suite couldn't be opened -- rather than crash
            // (widget extension crashes are disruptive system-wide, unlike
            // a container-app failure), degrade to "no data to show," the
            // same state as a genuine cache miss.
            cache = nil
            refreshScheduler = nil
        }
    }

    func placeholder(in context: Context) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: Date(), reading: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BluegullAQIWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BluegullAQIWidgetEntry>) -> Void) {
        let nextRefresh = refreshScheduler?.nextRefreshDate() ?? Date().addingTimeInterval(RefreshScheduler.defaultInterval)
        completion(Timeline(entries: [currentEntry()], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: Date(), reading: cache?.mostRecentEntry())
    }
}

/// Still a placeholder view -- real per-family layouts (small/medium/large)
/// are separate tracked scope (bluegull-aqi-mtm.4/mtm.5/mtm.6), not this
/// task. `entry.reading` now genuinely flows from the App Group cache
/// (bluegull-aqi-mtm.2), but rendering it meaningfully is deliberately not
/// attempted here.
struct BluegullAQIWidgetView: View {
    let entry: BluegullAQIWidgetEntry

    var body: some View {
        Text(NowCastCopy.headline)
    }
}

struct BluegullAQIWidget: Widget {
    let kind = "BluegullAQIWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BluegullAQIWidgetTimelineProvider()) { entry in
            BluegullAQIWidgetView(entry: entry)
        }
        .configurationDisplayName(NowCastCopy.headline)
        .description("Local air quality at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
