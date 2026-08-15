import SwiftUI
import BluegullAQIKit

/// The AQI badge (color dot + number + category descriptor) and two-tier
/// attribution footer, extracted out of `AQIPopoverView` (bluegull-aqi-
/// e70.11) so `WidgetDetailView` (bluegull-aqi-mtm.14) can show the exact
/// same content the popover does, per that issue's explicit instruction to
/// reuse "content/view code from the menu bar popover rather than building
/// a third separate compliance surface."
struct AQIHeadlineBadge: View {
    let aqi: Int
    let category: AQICategory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(category.color.swiftUIColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(aqi)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(category.descriptor)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Reverse-geocoded place name for "Current Location" (bluegull-aqi-e70.27)
/// -- Steve wanted a way to verify GPS actually resolved to where he
/// expects, since the bare "Current Location" label gives no indication
/// what coordinate it actually used. Callers show this only for the
/// synthetic current-location option; a pinned location already has its
/// own human-chosen name and doesn't need a second one.
///
/// Resolves itself on appear/location-change via `.task(id:)`, same
/// self-contained-async-load pattern as `AirNowAPIKeyEntryView`/
/// `PinnedLocationsView` elsewhere in this file's sibling views -- no
/// state threaded in from a caller. Falls back to raw coordinates while
/// resolving or if reverse geocoding fails outright (no network, no
/// result) -- always shows *something* verifiable rather than silently
/// showing nothing, which would look like the feature doesn't exist.
struct ResolvedPlaceNameCaption: View {
    let location: Location
    var resolver: LocationResolver = LocationResolver()

    @State private var placeName: String?

    var body: some View {
        Text("Near \(placeName ?? coordinateText)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .task(id: location) {
                placeName = try? await resolver.placeName(for: location)
            }
    }

    private var coordinateText: String {
        String(format: "%.2f, %.2f", location.latitude, location.longitude)
    }
}

/// Two-tier attribution (bluegull-aqi-e70.10, bluegull-aqi-10h.15): credit
/// the specific reporting agency for this reading first, when AirNow
/// supplied one, then the static AirNow/EPA credit -- always shown, never
/// omitted.
struct AttributionFooter: View {
    let headline: PollutantReading

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let agencyCredit = headline.attributionText {
                Text(agencyCredit)
            }
            Text(AttributionCopy.staticCredit)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The in-product preliminary-data disclaimer (bluegull-aqi-dc2.4) --
/// shown alongside `AttributionFooter` in both compliance surfaces (the
/// menu bar popover and the widget's tap-to-expand detail view), same
/// reuse rationale as that view.
struct DisclaimerFooter: View {
    var body: some View {
        Text(AttributionCopy.preliminaryDataDisclaimer)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// `UserDefaults.standard` (container-app-only, like
/// `MenuBarLocationSelectionStore`'s own doc comment on why it isn't in the
/// App Group -- the widget extension has no menu bar item to render, so it
/// has no use for this preference).
enum MenuBarAppearanceStore {
    static let colorPillEnabledKey = "menuBarCategoryColorPillEnabled"
    static let defaultColorPillEnabled = true

    // bluegull-aqi-e70.29: off by default -- Steve's own concern raising
    // this was that a permanent label would eat into scarce menu bar real
    // estate alongside his other menu bar items, unlike the color pill
    // above, which he wanted on by default.
    static let aqiLabelEnabledKey = "menuBarAQILabelEnabled"
    static let defaultAQILabelEnabled = false
}

/// Settings toggle for `MenuBarStatusLabel`'s colored-pill vs. plain-dot
/// styling (bluegull-aqi-e70.26). A separate `Toggle`, not folded directly
/// into `SettingsView`, matching `DataSourceModeToggle`'s own precedent of
/// one file per settings control.
struct MenuBarColorStyleToggle: View {
    @AppStorage(MenuBarAppearanceStore.colorPillEnabledKey)
    private var isColorPillEnabled = MenuBarAppearanceStore.defaultColorPillEnabled

    var body: some View {
        Toggle("Show AQI category color in menu bar", isOn: $isColorPillEnabled)
            .accessibilityIdentifier("menuBarColorStyleToggle")
    }
}

/// Settings toggle for `MenuBarStatusLabel`'s optional "AQI" label next to
/// the bare number (bluegull-aqi-e70.29). Same one-struct-per-control
/// precedent as `MenuBarColorStyleToggle` just above.
struct MenuBarAQILabelToggle: View {
    @AppStorage(MenuBarAppearanceStore.aqiLabelEnabledKey)
    private var isAQILabelEnabled = MenuBarAppearanceStore.defaultAQILabelEnabled

    var body: some View {
        Toggle("Show \"AQI\" label in menu bar", isOn: $isAQILabelEnabled)
            .accessibilityIdentifier("menuBarAQILabelToggle")
    }
}

/// The menu bar status item's own content (bluegull-aqi-e70.6) -- distinct
/// from `AQIHeadlineBadge`, which is sized for the popover/detail view, not
/// the tiny always-visible menu bar sliver. Falls back to a generic
/// template icon when there's no reading yet (never fetched, or the most
/// recent fetch failed with nothing previously cached to fall back to).
///
/// Also falls back -- to the same icon plus an em dash -- once `freshness`
/// says the reading is no longer fresh (bluegull-aqi-e70.31). Steve was
/// explicit: "I never want to show stale data on the menu bar... no one
/// will notice it's stale." A single glanceable number with a category
/// color has no visual room to qualify itself as aged, unlike the popover
/// (which shows an explicit timestamp) or the widget (which will show one
/// per bluegull-aqi-dc2.6/dc2.7) -- so this surface's bar is stricter: past
/// fresh means "don't show the number at all," not "show it dimmed."
///
/// The dash was chosen over the bare icon alone after Steve reviewed
/// rendered mockups of both: the icon alone reads as decorative and
/// communicates nothing, while an icon it's already using for "no reading
/// yet" doesn't distinguish "never fetched" from "went stale" -- the dash
/// is the conventional "no value in this slot" mark and reads as neither
/// mid-fetch (which an ellipsis would suggest, and nothing is fetching) nor
/// alarming (which a "?" would).
struct MenuBarStatusLabel: View {
    let reading: AQIReading?
    let freshness: AQIFreshness?

    // bluegull-aqi-e70.26: Steve's feedback was that the existing 8pt dot
    // undersells the category color. NOTE: the claim that the dot was
    // already rendering in color on a real menu bar turned out to be
    // unverified, not confirmed -- Steve himself wasn't certain he'd ever
    // actually looked closely enough to check, and the first version of
    // this feature (a live colored `Text`) shipped with zero color at all
    // on his real menu bar despite rendering fine under `ImageRenderer`.
    // What IS confirmed, as of the pre-rasterized-bitmap fix below
    // (2026-08-14): a pre-rendered `Image` DOES render in full color on
    // Steve's real menu bar. Defaults on since this is Steve's own request;
    // the toggle exists for anyone who prefers a quieter,
    // HIG-conventional monochrome-ish menu bar.
    @AppStorage(MenuBarAppearanceStore.colorPillEnabledKey)
    private var isColorPillEnabled = MenuBarAppearanceStore.defaultColorPillEnabled

    // bluegull-aqi-e70.29
    @AppStorage(MenuBarAppearanceStore.aqiLabelEnabledKey)
    private var isAQILabelEnabled = MenuBarAppearanceStore.defaultAQILabelEnabled

    var body: some View {
        if let reading, freshness == .fresh,
           let headline = reading.headlinePollutant,
           let aqi = headline.nowcastAQI, let category = headline.category {
            if isColorPillEnabled, let pillImage = pillImage(aqi: aqi, category: category) {
                // Rendered as a pre-rasterized bitmap, not live `Text` --
                // confirmed against the real running app (not assumed):
                // `MenuBarExtra` forces `Text` color/background modifiers
                // to the system's default menu-bar style regardless of
                // container nesting, a documented SwiftUI limitation (both
                // a bare colored `Text` and an `HStack`-wrapped one rendered
                // with no color at all on Steve's actual menu bar, despite
                // rendering correctly under `ImageRenderer`, which doesn't
                // reproduce that restriction). Switching to a pre-rendered
                // `Image` was confirmed by Steve to fix it (2026-08-14) --
                // pre-rasterizing the colored-background + contrasting-text
                // pattern from `AQICategory.color.contrastingTextColor`'s
                // own doc comment (bluegull-aqi-mtm.19) into a bitmap
                // sidesteps the `Text`-specific restriction instead of
                // fighting it.
                Image(nsImage: pillImage)
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(category.color.swiftUIColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    Text(labelText(aqi: aqi))
                }
            }
        } else if reading != nil {
            // A reading exists but isn't `.fresh` (`.stale`, or freshness
            // itself somehow unavailable for it) -- distinct from the
            // never-fetched case below only in spirit; both render
            // identically on purpose, since a stale number is exactly as
            // unusable to glance at as no number.
            HStack(spacing: 4) {
                Image(systemName: "aqi.medium")
                Text("—")
            }
        } else {
            Image(systemName: "aqi.medium")
        }
    }

    // `size: 13` matches `NSFont.menuBarFont(ofSize: 0)`'s default point
    // size (13pt) -- not derived programmatically, since this content never
    // touches an `NSFont` API, just chosen to look right alongside the
    // system's own menu bar text. `renderer.scale = 2` for a Retina-sharp
    // bitmap; the label pixel size is whatever the rendered content's own
    // padding/font produce, same as `WidgetRenderHarness` and
    // `GoldenImageAssertion` both already rely on `ImageRenderer` sizing to
    // its content rather than an explicit `.frame`.
    // bluegull-aqi-e70.29: "AQI 45", not "45 AQI" -- Steve's call, label
    // before value.
    private func labelText(aqi: Int) -> String {
        isAQILabelEnabled ? "AQI \(aqi)" : "\(aqi)"
    }

    @MainActor
    private func pillImage(aqi: Int, category: AQICategory) -> NSImage? {
        let content = Text(labelText(aqi: aqi))
            .font(.system(size: 13))
            .foregroundStyle(category.color.contrastingTextColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(category.color.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }
}
