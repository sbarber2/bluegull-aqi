import WidgetKit
import SwiftUI
import BluegullAQIKit

/// Scaffold only (bluegull-aqi-mtm.1): a real `TimelineProvider` reading the
/// App Group cache is separate tracked work (bluegull-aqi-mtm.2), and
/// per-instance configuration via App Intents is bluegull-aqi-mtm.3. This
/// placeholder proves the extension target builds, embeds in the container
/// app, and links `BluegullAQIKit` -- nothing more.
struct BluegullAQIWidgetEntry: TimelineEntry {
    let date: Date
}

struct BluegullAQIWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (BluegullAQIWidgetEntry) -> Void) {
        completion(BluegullAQIWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BluegullAQIWidgetEntry>) -> Void) {
        completion(Timeline(entries: [BluegullAQIWidgetEntry(date: Date())], policy: .never))
    }
}

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
