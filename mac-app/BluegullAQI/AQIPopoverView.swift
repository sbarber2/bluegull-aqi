import AppKit
import SwiftUI
import BluegullAQIKit

/// The `.window`-style popover content shown when the menu bar status item
/// is clicked (bluegull-aqi-e70.11). A "dumb" presentational view -- takes
/// whatever reading it's given and renders it; `AQIRefreshController`
/// (bluegull-aqi-e70.6/e70.7) is what actually fetches and supplies a live
/// `AQIReading`. Attribution (bluegull-aqi-e70.10) and the preliminary-data
/// disclaimer (bluegull-aqi-dc2.4) are both rendered.
struct AQIPopoverView: View {
    // bluegull-aqi-e70.27: same key `MenuBarLocationPicker` itself reads,
    // independently -- matching precedent elsewhere in this codebase (e.g.
    // `MenuBarStatusLabel`/`MenuBarColorStyleToggle` both independently
    // read `MenuBarAppearanceStore.colorPillEnabledKey`). Needed here only
    // to decide whether to show the resolved-place-name caption below --
    // a pinned location already has its own human-chosen name in the
    // picker, so this only applies to the synthetic "current location"
    // option.
    @AppStorage(MenuBarLocationSelectionStore.userDefaultsKey)
    private var selectedLocationID: String = MenuBarLocationSelectionStore.defaultSelectionID

    let reading: AQIReading?

    // Shown as a compact warning alongside `reading` when both are present
    // (bluegull-aqi-dc2.1), or as the sole full-page state when there's no
    // reading to fall back on at all. A real, confirmed gap before this
    // existed at all: AQIRefreshController always tracked this correctly,
    // but nothing in the UI ever read it, so a failed fetch (e.g. Service
    // mode when BluegullServiceClient didn't exist yet, bluegull-aqi-10h.4)
    // silently left whatever Direct-mode reading was already showing
    // frozen in place, with zero indication anything had gone wrong. Found
    // by Steve in a real run: "changed the setting from Direct to Service,
    // the app did not display new values... changed back to direct, all
    // was well." Originally this replaced `reading` outright rather than
    // supplementing it -- revisited for dc2.1 once `lastFetchedAt` existed
    // to make "how stale is what I'm looking at" explicit instead of
    // discarding perfectly good cached data over one transient failure.
    let lastError: AQIFetchError?

    // When the last successful fetch completed, independent of `reading`'s
    // own cache TTL (bluegull-aqi-dc2.1) -- lets the popover say "Updated X
    // ago" instead of silently presenting `reading` as if it were always
    // current.
    let lastFetchedAt: Date?

    // Called after the location picker's selection changes, so the caller
    // (BluegullAQIApp) can trigger an immediate refetch for the newly
    // selected location (bluegull-aqi-e70.21) rather than waiting for the
    // next scheduled refresh, up to an hour away.
    let onLocationChange: () -> Void

    // bluegull-aqi-e70.27: injectable so render tests can substitute a
    // fake-backed resolver instead of `ResolvedPlaceNameCaption`'s own
    // default hitting real CLGeocoder -- same reasoning as every other
    // "never touches real CoreLocation in tests" type in this codebase.
    var locationResolver: LocationResolver = LocationResolver()

    // Opens Settings as its own real window (see BluegullAQIApp's
    // Window(id: "settings")), NOT a .sheet() -- a .sheet() presented from
    // inside a MenuBarExtra's .window-style popover is unreliable in
    // practice: the popover is a lightweight NSPanel that can lose key
    // status and dismiss itself (taking the sheet down with it) when the
    // user interacts with certain controls inside, and its cropped-to-the-
    // popover's-own-size sheet sizing looked visibly wrong besides.
    // Confirmed both symptoms in a real interactive run, not theorized.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                MenuBarLocationPicker(onChange: onLocationChange)
                Spacer()
                Button {
                    // LSUIElement (agent) apps aren't reliably made
                    // frontmost just by a window being created -- explicit
                    // activation is what actually brings it forward.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsButton")
            }
            if let reading, selectedLocationID == MenuBarLocationSelectionStore.defaultSelectionID {
                ResolvedPlaceNameCaption(location: reading.location, resolver: locationResolver)
            }

            if let reading,
               let headline = reading.headlinePollutant,
               let aqi = headline.nowcastAQI,
               let category = headline.category {
                // bluegull-aqi-dc2.1: a failed refresh no longer hides
                // otherwise-good cached data -- only a genuinely empty
                // `reading` falls through to the full-page error below.
                // Still surfaces *why* the last refresh failed, right next
                // to how old what's showing now actually is.
                if let lastError {
                    staleWarningBanner(lastError.userMessage)
                }
                AQIHeadlineBadge(aqi: aqi, category: category)
                if let notice = category.beyondScaleNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastFetchedAt {
                    updatedCaption(lastFetchedAt)
                }
                Divider()
                PollutantListView(pollutants: reading.pollutants)
                Divider()
                AttributionFooter(headline: headline)
                DisclaimerFooter()
            } else if let lastError {
                ContentUnavailableView(
                    "Can't Show Air Quality",
                    systemImage: "exclamationmark.triangle",
                    description: Text(lastError.userMessage)
                )
            } else {
                ContentUnavailableView(
                    "No Air Quality Data",
                    systemImage: "aqi.medium",
                    description: Text("BlueGull AQI hasn't fetched a reading yet.")
                )
            }

            // LSUIElement (menu bar-only, bluegull-aqi-e70.1) means no Dock
            // icon and no standard app menu -- without this, quitting
            // needs Activity Monitor or a terminal `pkill`. Found the hard
            // way: this genuinely didn't exist until Steve asked, having
            // just hit exactly that dead end.
            Divider()
            Button("Quit BlueGull AQI") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("quitButton")
        }
        .padding()
        .frame(width: 300)
    }

    private func staleWarningBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // Live-updating (`Text(_:style:)`, not a formatted-once String) so it
    // stays accurate the whole time the popover is open, without this view
    // needing its own timer -- unlike the widget's equivalent
    // (`BluegullAQIWidgetView`'s `staleCaption`), which formats a fixed
    // string against WidgetKit's own Timeline "now" instead, since
    // ImageRenderer-based golden-image snapshot tests need byte-stable
    // output, not a live clock.
    private func updatedCaption(_ date: Date) -> some View {
        // `Text(_:style: .relative)` already renders "2 hours ago" on its
        // own (Apple's own example for this style) -- no extra "ago" to
        // append.
        (Text("Updated ") + Text(date, style: .relative))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

}
