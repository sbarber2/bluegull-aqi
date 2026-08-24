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

    // Same App Group as `computer`/`refreshController` -- re-derives which
    // pinned location this is from the current list (bluegull-aqi-mtm.27),
    // since the deep link that opened this view only carries coordinates,
    // not the name the widget face itself was configured with. See
    // `WidgetLocationOptions.displayName(for:from:)`'s own doc comment.
    private let pinnedLocationsStore: PinnedLocationsStore

    private var locationName: String {
        WidgetLocationOptions.displayName(for: location, from: pinnedLocationsStore)
    }

    // `@State`, not a computed property, so a fetch triggered below can
    // actually update what's on screen (bluegull-aqi-mtm.21) -- opening
    // this view used to not be a signal to fetch at all, which meant a
    // widget pointed at a location nothing else had ever fetched just
    // stayed on "No Data" forever, even with this window open and staring
    // right at it.
    @State private var reading: AQIReading?

    // bluegull-aqi-e70.42: this view had no staleness indication at all
    // before -- unlike the widget face itself (dc2.5/dc2.6) and the menu
    // bar popover (its own lastError banner), tapping through to "Air
    // Quality Detail" showed a reading with zero indication it might be
    // aged, or that the active data source might be currently failing
    // (see WidgetTimelineComputer.currentSnapshot, which already folds
    // bluegull-aqi-e70.39's cross-process failure signal into this exact
    // value).
    @State private var freshness: AQIFreshness?

    // bluegull-aqi-e70.48: this view previously had no fetch-time
    // equivalent of the popover's own `lastFetchedAt` at all -- only
    // `freshness` (fresh/stale/expired), never the actual instant. Sourced
    // from `WidgetTimelineSnapshot.lastSuccessfulFetchDate`, which already
    // existed in the widget's own data model (used by
    // `WidgetTimelineComputer`'s timeline entries) but was never surfaced
    // to this view before.
    @State private var lastFetchedAt: Date?

    // bluegull-aqi-e70.27: same injection reasoning as `AQIPopoverView`'s
    // own `locationResolver` property.
    private let locationResolver: LocationResolver

    // bluegull-aqi-e70.49: without this, `reading`/`freshness` above are set
    // once (by `.task(id:)` below) and never again -- a real bug found live:
    // leave this window open across a later successful fetch (by either
    // this process's own loop or the widget extension's independent one,
    // bluegull-aqi-mtm.24) and it just sits showing whatever it loaded at
    // open time, silently diverging from the menu bar/popover, which read a
    // live `@Observable` property and always show the current value.
    // Injected (not just called directly) so a test can simulate a change
    // without a real Darwin notification round-trip -- same reasoning as
    // `store`/`locationResolver` just above.
    private let changeObserver: CacheChangeObserving

    init(
        location: Location?,
        refreshController: AQIRefreshController? = nil,
        store: SharedCacheStore? = UserDefaultsCacheStore(),
        locationResolver: LocationResolver = LocationResolver(),
        changeObserver: CacheChangeObserving = DarwinCacheChangeObserver()
    ) {
        self.location = location
        self.refreshController = refreshController
        computer = store.map(WidgetTimelineComputer.init(store:))
        pinnedLocationsStore = PinnedLocationsStore(store: store)
        self.locationResolver = locationResolver
        self.changeObserver = changeObserver
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
                    // Steve, 2026-08-05: the detail view had no location
                    // name anywhere -- unlike the menu bar popover (which
                    // shows one via MenuBarLocationPicker), this view has
                    // no other element that identifies which of possibly
                    // several widgets' data it's showing. Trailing, next
                    // to the badge rather than a new row: there was room,
                    // and it reads as a label for the value beside it
                    // rather than competing with it.
                    HStack(alignment: .top) {
                        AQIHeadlineBadge(aqi: aqi, category: category)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(locationName)
                                .font(.body)
                                .foregroundStyle(.secondary)
                            // bluegull-aqi-e70.27: `location == nil` is
                            // exactly the "Current Location" case (see
                            // `locationName`'s own doc comment above) -- a
                            // pinned location already has its own name,
                            // this is only for verifying GPS resolved
                            // where expected.
                            if location == nil {
                                ResolvedPlaceNameCaption(location: reading.location, resolver: locationResolver)
                            }
                        }
                    }
                    if let notice = category.beyondScaleNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // bluegull-aqi-e70.48: replaces AgedReadingIndicator's
                    // stale-only *timestamp* text -- these two rows already
                    // show the same observation instant it did, unconditionally
                    // and with more precision, plus the fetch time it never
                    // showed at all. Showing both would just duplicate the
                    // observation timestamp when stale.
                    if let observedAt = headline.observedAt {
                        TimestampCaption(label: "Observed", date: observedAt, timeZone: headline.observedAtTimeZone)
                    }
                    if let lastFetchedAt {
                        TimestampCaption(label: "Updated", date: lastFetchedAt, timeZone: .current)
                    }
                    // NOT superseded by the timestamps above: `freshness`
                    // can be `.stale` even when `observedAt` looks recent,
                    // because WidgetTimelineComputer.currentSnapshot folds
                    // in whether the most recent fetch attempt (by either
                    // process) actually failed (bluegull-aqi-e70.39) -- a
                    // reading that's technically within its TTL is exactly
                    // as untrustworthy as an aged one in that case, and
                    // nothing in the timestamps themselves would show it
                    // (they'd just read as recent). This is the only signal
                    // for that in this view, so it stays, just without
                    // repeating the observation instant text
                    // AgedReadingIndicator used to also carry.
                    if freshness == .stale {
                        Label("Data may be out of date", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
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
            refreshFromCache()
            if reading == nil {
                await refreshController?.fetchIfNeeded(for: location)
                refreshFromCache()
            }
            // bluegull-aqi-e70.49: keeps this window live for as long as
            // `location` (this task's own id) stays selected -- a location
            // change cancels this loop the same way it already cancels the
            // fetch-on-open logic above (that's what `.task(id:)`, not a
            // bare `.task`, buys both of them), so there's never a stale
            // subscription still refreshing for a location this window has
            // since moved on from.
            for await _ in changeObserver.changes() {
                refreshFromCache()
            }
        }
    }

    private func refreshFromCache() {
        let snapshot = computer?.currentSnapshot(for: location)
        reading = snapshot?.reading
        freshness = snapshot?.freshness
        lastFetchedAt = snapshot?.lastSuccessfulFetchDate
    }
}
