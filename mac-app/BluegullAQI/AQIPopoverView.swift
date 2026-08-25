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
    // bluegull-aqi-e70.27: the *resolved* selection (fallback-aware, not a
    // raw AppStorage string) reported by `MenuBarLocationPicker` -- needed
    // here only to decide whether to show the resolved-place-name caption
    // below; a pinned location already has its own human-chosen name in
    // the picker, so this only applies to the synthetic "current location"
    // option. See `MenuBarLocationPicker.onResolvedSelectionChange`'s own
    // doc comment for why comparing a raw stored ID against the literal
    // "current" sentinel was wrong.
    @State private var resolvedLocationOption: LocationOption = .currentLocation

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
                // `.tint` here, not `.foregroundStyle` -- `MenuBarLocationPicker`
                // is a stock `.menu`-style `Picker` (MenuBarLocationPicker.swift),
                // which macOS renders as a native pull-down control; `.tint`
                // is the modifier that actually reaches a Picker's own label
                // text/chevron color on that style, `.foregroundStyle` is
                // documented to not reliably affect it. NOT independently
                // confirmed live yet that this reads well against
                // AppBrand's background -- worth a specific look, unlike
                // the plain-Text elements elsewhere in this file which are
                // straightforward to reason about.
                MenuBarLocationPicker(
                    onChange: onLocationChange,
                    onResolvedSelectionChange: { resolvedLocationOption = $0 }
                )
                .tint(AppBrand.navy)
                Spacer()
                Button {
                    // LSUIElement (agent) apps aren't reliably made
                    // frontmost just by a window being created -- explicit
                    // activation is what actually brings it forward.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    // Fixed navy, not the default adaptive tint -- this
                    // sits at the very top, over AppBrand's lighter top
                    // gradient stop.
                    Image(systemName: "gearshape")
                        .foregroundStyle(AppBrand.navy.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsButton")
            }
            if let reading, resolvedLocationOption == .currentLocation {
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
                        .foregroundStyle(.white.opacity(0.82))
                }
                brandDivider
                PollutantListView(pollutants: reading.pollutants)
                // bluegull-aqi-e70.48: both timestamps, always shown (not
                // gated on freshness) -- observation time (the reporting
                // station's own instant/zone) and update time (when this
                // app itself last fetched, in the viewer's own zone) can
                // genuinely differ, so both are shown rather than picking
                // one. Below the pollutant list, not above it (Steve,
                // 2026-08-24) -- tight inner spacing (2, not the outer
                // VStack's 16) since these two rows read as one related
                // group.
                VStack(alignment: .leading, spacing: 2) {
                    if let observedAt = headline.observedAt {
                        TimestampCaption(label: "Observed", date: observedAt, timeZone: headline.observedAtTimeZone)
                    }
                    if let lastFetchedAt {
                        TimestampCaption(label: "Updated", date: lastFetchedAt, timeZone: .current)
                    }
                }
                brandDivider
                AttributionAndDisclaimerText(headline: headline)
            } else if let lastError {
                // .white best-effort: stock SwiftUI `ContentUnavailableView`
                // doesn't expose its internal title/description styling
                // directly, so this chains a top-level foregroundStyle
                // rather than editing text that isn't reachable here. NOT
                // independently confirmed live yet whether it actually
                // recolors both the title and the description, or just
                // one -- worth a specific look.
                ContentUnavailableView(
                    "Can't Show Air Quality",
                    systemImage: "exclamationmark.triangle",
                    description: Text(lastError.userMessage)
                )
                .foregroundStyle(.white)
            } else {
                ContentUnavailableView(
                    "No Air Quality Data",
                    systemImage: "aqi.medium",
                    description: Text("BlueGull AQI hasn't fetched a reading yet.")
                )
                .foregroundStyle(.white)
            }

            // LSUIElement (menu bar-only, bluegull-aqi-e70.1) means no Dock
            // icon and no standard app menu -- without this, quitting
            // needs Activity Monitor or a terminal `pkill`. Found the hard
            // way: this genuinely didn't exist until Steve asked, having
            // just hit exactly that dead end.
            brandDivider
            Button("Quit BlueGull AQI") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .accessibilityIdentifier("quitButton")
        }
        .padding()
        .frame(width: 300)
        // bluegull-aqi-e70.52: the branded background, extending Steve's
        // widget-face request (bluegull-aqi-e70.51) to this surface for
        // visual consistency. No WidgetKit container-margin complication
        // here (unlike the widget faces) -- this is a plain SwiftUI
        // popover, so an ordinary `.background()` is genuinely full-bleed,
        // no second call needed. Small `midStopLocation` (AppBrand's own
        // default, 0.12): this view's content height varies a lot
        // (error/empty states vs. a full pollutant list plus timestamps
        // plus the attribution paragraph), and only the very top row
        // (location picker, resolved place) ever needs the lighter top.
        .background(AppBrand.backgroundGradient())
    }

    private func staleWarningBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            // bluegull-aqi-e70.40: without this, a longer message (e.g.
            // AQIFetchError.serviceModeError's own text) truncated with an
            // ellipsis instead of wrapping -- Text/Label don't grow
            // vertically inside a VStack on their own; this tells SwiftUI
            // to size for the wrapped content instead of clipping to a
            // single line's height.
            .fixedSize(horizontal: false, vertical: true)
    }

    // Fixed white hairline, not the default `Divider()` -- that renders as
    // adaptive system gray, which doesn't read against AppBrand's
    // background (bluegull-aqi-e70.52), same fix as the widget faces'
    // own (bluegull-aqi-e70.51).
    private var brandDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.28))
            .frame(height: 1)
    }
}
