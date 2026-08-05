import SwiftUI
import BluegullAQIKit

/// Reachable via the widget's tap target (`widgetURL` → `WidgetDeepLink`,
/// bluegull-aqi-mtm.14) -- shown in its own window (see `BluegullAQIApp`)
/// so a user who has the widget on their desktop but has never opened the
/// menu bar popover still has a reachable path to attribution and the
/// preliminary-data disclaimer (doc/DESIGN.md "AirNow terms review"
/// findings 1 and 2; disclaimer wording decided in bluegull-aqi-dc2.4).
///
/// Also shows the full pollutant breakdown (`PollutantListView`,
/// bluegull-aqi-mtm.15's pollutant-breakdown slice, pulled forward from
/// its original POST-v1 deferral 2026-08-01) -- the widget face itself
/// only shows the breakdown at `.systemLarge` (`LargeWidgetLayout`); this
/// is the one place small/medium widget users can see it without also
/// opening the menu bar popover.
struct WidgetDetailView: View {
    let location: Location?
    let refreshController: AQIRefreshController?

    // Reads directly from the App Group cache, the same source
    // `WidgetTimelineComputer` gives the widget itself.
    private let computer: WidgetTimelineComputer?

    // `@State`, not a computed property, so a fetch triggered below can
    // actually update what's on screen (bluegull-aqi-mtm.21) -- opening
    // this view used to not be a signal to fetch at all, which meant a
    // widget pointed at a location nothing else had ever fetched just
    // stayed on "No Data" forever, even with this window open and staring
    // right at it.
    @State private var reading: AQIReading?

    init(location: Location?, refreshController: AQIRefreshController? = nil, store: SharedCacheStore? = UserDefaultsCacheStore()) {
        self.location = location
        self.refreshController = refreshController
        computer = store.map(WidgetTimelineComputer.init(store:))
    }

    var body: some View {
        // ScrollView, not a bare VStack -- this Window's frame is persisted
        // across launches by AppKit's own autosave (keyed off the Window's
        // `id`), independent of `.windowResizability(.contentSize)`'s
        // "ideal size" below. A frame saved back when this view needed less
        // height (fewer pollutants, or before the disclaimer reached its
        // current length) gets restored as-is on a later launch, squeezing
        // this content into less space than it now needs -- confirmed from
        // a real saved frame this session ("NSWindow Frame widget-detail"
        // = "... 320 273 ..."). A plain VStack has no way to signal that
        // it's been clipped; `Text` just silently truncates with "…" to
        // fit. Wrapping in a ScrollView means the full content, including
        // the compliance-required disclaimer, is always at least
        // reachable by scrolling, regardless of whatever height the
        // restored frame turns out to be.
        ScrollView {
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
                    PollutantListView(pollutants: reading.pollutants)
                    Divider()
                    AttributionFooter(headline: headline)
                    DisclaimerFooter()
                } else {
                    ContentUnavailableView(
                        "No Air Quality Data",
                        systemImage: "aqi.medium",
                        description: Text("BlueGull AQI hasn't cached a reading for this widget yet.")
                    )
                }
            }
            .padding()
        }
        .frame(width: 320)
        .accessibilityIdentifier("widgetDetailView")
        // `.task(id:)`, not `.task` -- this is a singleton Window
        // (bluegull-aqi-mtm.14), so a second widget tap while it's already
        // open reuses the same view with a new `location` rather than
        // creating a fresh one; re-running for the new id is what makes
        // that case fetch too, not just the window's first-ever open.
        .task(id: location) {
            reading = computer?.currentSnapshot(for: location).reading
            guard reading == nil else { return }
            await refreshController?.fetchIfNeeded(for: location)
            reading = computer?.currentSnapshot(for: location).reading
        }
    }
}
