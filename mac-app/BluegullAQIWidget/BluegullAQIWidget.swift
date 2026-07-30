import WidgetKit
import SwiftUI
import BluegullAQIKit

struct BluegullAQIWidgetEntry: TimelineEntry {
    let date: Date
    let reading: AQIReading?

    init(date: Date, reading: AQIReading?) {
        self.date = date
        self.reading = reading
    }

    init(_ snapshot: WidgetTimelineSnapshot) {
        date = snapshot.date
        reading = snapshot.reading
    }
}

/// Thin `TimelineProvider` glue -- the actual cache-reading/reload-policy
/// logic lives in `BluegullAQIKit.WidgetTimelineComputer` (bluegull-aqi-mtm.2),
/// specifically so it's unit-testable at all (an `app-extension` target
/// can't be linked against by a separate test target -- see that type's
/// doc comment). Never fetches network or location itself
/// (doc/DESIGN.md "Widget extension (WidgetKit)").
struct BluegullAQIWidgetTimelineProvider: TimelineProvider {
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

    func getSnapshot(in context: Context, completion: @escaping (BluegullAQIWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BluegullAQIWidgetEntry>) -> Void) {
        let now = Date()
        let nextReload = computer?.nextReloadDate(after: now) ?? now.addingTimeInterval(RefreshScheduler.defaultInterval)
        completion(Timeline(entries: [entry(now: now)], policy: .after(nextReload)))
    }

    private func entry(now: Date = Date()) -> BluegullAQIWidgetEntry {
        guard let computer else { return BluegullAQIWidgetEntry(date: now, reading: nil) }
        return BluegullAQIWidgetEntry(computer.currentSnapshot(now: now))
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
