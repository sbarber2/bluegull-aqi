import SwiftUI
import BluegullAQIKit

/// Reachable via the widget's tap target (`widgetURL` → `WidgetDeepLink`,
/// bluegull-aqi-mtm.14) -- shown in its own window (see `BluegullAQIApp`)
/// so a user who has the widget on their desktop but has never opened the
/// menu bar popover still has a reachable path to attribution
/// (doc/DESIGN.md "AirNow terms review" findings 1 and 2).
///
/// Deliberately does NOT render a preliminary-data disclaimer -- same
/// reasoning as `AQIPopoverView`'s own doc comment: its exact wording is a
/// compliance call for Steve to make (bluegull-aqi-dc2.4), not something to
/// invent here. That's why `dc2.4` depends on this issue rather than the
/// reverse: this view exists first, `dc2.4` adds the disclaimer into it
/// once the wording is decided.
struct WidgetDetailView: View {
    let location: Location?

    // Reads directly from the App Group cache, the same source
    // `WidgetTimelineComputer` gives the widget itself -- the container app
    // has no live fetch pipeline wired up yet (bluegull-aqi-e70.6/e70.7),
    // so this shows whatever the widget was already showing, not a fresh
    // fetch trigger.
    private let computer: WidgetTimelineComputer?

    init(location: Location?, store: SharedCacheStore? = UserDefaultsCacheStore()) {
        self.location = location
        computer = store.map(WidgetTimelineComputer.init(store:))
    }

    private var reading: AQIReading? {
        computer?.currentSnapshot(for: location).reading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let reading,
               let headline = reading.headlinePollutant,
               let aqi = headline.nowcastAQI,
               let category = headline.category {
                AQIHeadlineBadge(aqi: aqi, category: category)
                if let notice = category.beyondScaleNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                AttributionFooter(headline: headline)
            } else {
                ContentUnavailableView(
                    "No Air Quality Data",
                    systemImage: "aqi.medium",
                    description: Text("BlueGull AQI hasn't cached a reading for this widget yet.")
                )
            }
        }
        .padding()
        .frame(width: 320)
        .accessibilityIdentifier("widgetDetailView")
    }
}
