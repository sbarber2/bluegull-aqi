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
                // White, not `Color.primary.opacity(0.15)` -- this sat
                // below a plain adaptive background before; AppBrand's
                // fixed navy-ish background (both call sites now use it)
                // needs a light ring for the same subtle-definition
                // purpose, not a dark one that all but vanishes against a
                // dark fill.
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                // Fixed white, not the default adaptive `.primary` -- both
                // call sites (AQIPopoverView, WidgetDetailView) now show
                // this over AppBrand's fixed background.
                Text("\(aqi)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(category.descriptor)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
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
        // Fixed navy, not adaptive `.secondary` -- both call sites
        // (AQIPopoverView, WidgetDetailView) show this at the very top of
        // their content, over AppBrand's lighter top gradient stop.
        Text("Near \(placeName ?? coordinateText)")
            .font(.caption2)
            .foregroundStyle(AppBrand.navy.opacity(0.62))
            .task(id: location) {
                placeName = try? await resolver.placeName(for: location)
            }
    }

    private var coordinateText: String {
        String(format: "%.2f, %.2f", location.latitude, location.longitude)
    }
}

/// Aged-reading indicator (bluegull-aqi-e70.42) -- same clock-badge icon +
/// absolute-timestamp caption already used in the widget faces themselves
/// (`BluegullAQIWidgetView`'s own `agedReadingRow`/`agedReadingCaption`,
/// bluegull-aqi-dc2.6/dc2.7), reimplemented here rather than shared as one
/// type: those live in the separate `BluegullAQIWidgetViews` module, which
/// this app target doesn't depend on. `WidgetDetailView` had NO staleness
/// indication at all before this -- found by Steve testing the widget's
/// own e70.39 fix: "the widget has the stale (clock) indicator now... Not
/// [sic] that the Air Quality Detail popup has no indication of staleness
/// at all."
///
/// Absolute, not relative (bluegull-aqi-dc2.7's own format constraint) --
/// `headline.observedAtDisplay` is the actual AirNow observation instant,
/// in the observation's own reporting-area zone.
struct AgedReadingIndicator: View {
    let headline: PollutantReading

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
            if let observedAt = headline.observedAtDisplay {
                Text(observedAt)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// One labeled timestamp row -- absolute date/time/timezone at 1-second
/// resolution, with a live-updating relative time in parentheses (bluegull-
/// aqi-e70.48), e.g. "Observed: Tue Aug 12, 2026, 5:00:00 PM EDT (2 hours
/// ago)". The one shared component both `AQIPopoverView` and
/// `WidgetDetailView` use for both their "Observed" and "Updated" rows --
/// before this existed, each view formatted its own "last updated" caption
/// independently (relative-only in the popover, minute-resolution and
/// stale-only in the widget detail window), which is exactly how they'd
/// diverged into two different formats in the first place.
///
/// The relative suffix reuses `Text(_:style: .relative)`'s own live-update
/// behavior -- SwiftUI re-renders it on its own tick, no `Timer` needed here,
/// same mechanism `AQIPopoverView`'s previous `updatedCaption` already relied
/// on. The absolute portion is a fixed string computed once from `date` and
/// `timeZone`: unlike the relative text, an already-happened instant's own
/// calendar date/time/timezone never changes, so -- unlike the relative
/// suffix -- it doesn't need to re-render on a clock tick to stay correct.
///
/// Absolute text and the relative parenthetical are on two separate lines,
/// not one flowing line -- found live (Steve, 2026-08-24) that a single
/// concatenated line wraps wherever it runs out of width, which can split
/// the relative phrase itself (e.g. "...(2 hours" / "ago)"), orphaning
/// "ago)" alone on its own line. Two fixed lines means the relative clause
/// -- always short -- either fits whole or doesn't render, never splits.
/// Both lines get `.fixedSize(horizontal: false, vertical: true)`: without
/// it, a `Text` constrained by the caller's own fixed-width frame (e.g. the
/// popover's `.frame(width: 300)`) truncates with an ellipsis instead of
/// wrapping -- same bug, same fix as `AQIPopoverView`'s own
/// `staleWarningBanner` (bluegull-aqi-e70.40) elsewhere in this file's
/// sibling.
///
/// `date` is non-optional; callers decide whether a timestamp exists at all
/// (`if let`), same as the caption call sites this replaces.
struct TimestampCaption: View {
    let label: String
    let date: Date
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(label): \(Self.absoluteText(for: date, in: timeZone))")
                .fixedSize(horizontal: false, vertical: true)
            (Text("(") + Text(date, style: .relative) + Text(")"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        // Fixed white, not adaptive `.secondary` -- both call sites show
        // this well below the top of their content, over AppBrand's darker
        // gradient region.
        .foregroundStyle(.white.opacity(0.82))
    }

    // Not `private` -- exposed so `TimestampCaptionTests` can assert the
    // exact format/precision directly, the same way
    // `PollutantReading.observedAtDisplay` (a plain String property) is
    // tested directly rather than only through a render smoke test. A
    // SwiftUI `Text`'s own rendered content isn't otherwise inspectable
    // from XCTest without a snapshot, which would only prove "renders",
    // not "renders the right string."
    static func absoluteText(for date: Date, in timeZone: TimeZone) -> String {
        absoluteFormatter(for: timeZone).string(from: date)
    }

    // Fixed en_US locale, same determinism reasoning as
    // `PollutantReading.observedAtDisplay`'s own formatter -- this should
    // read the same regardless of the viewer's system locale, not vary with
    // it. "ss" for 1-second resolution (bluegull-aqi-e70.48's own spec),
    // unlike that property's minute-only precision -- a separate formatter
    // rather than reusing observedAtDisplay's, since changing that one's
    // precision would also change the widget face's own aged-reading
    // caption (BluegullAQIWidgetView, a different module with byte-stable
    // golden-image snapshot tests), which this bead never asked to touch.
    private static func absoluteFormatter(for timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d, yyyy, h:mm:ss a zzz"
        return formatter
    }
}

/// Two-tier attribution (bluegull-aqi-e70.10, bluegull-aqi-10h.15) plus the
/// preliminary-data disclaimer (bluegull-aqi-dc2.4), combined into one
/// continuous wrapped paragraph (bluegull-aqi-e70.48 follow-up, Steve
/// 2026-08-24) rather than the stacked separate lines `AttributionFooter`/
/// `DisclaimerFooter` used to render -- these two were always shown
/// together in both compliance surfaces (the menu bar popover and the
/// widget's tap-to-expand detail view) and are all boilerplate credit/
/// disclaimer text, not information a reader picks out individually, so one
/// flowing paragraph reads better than three stacked fragments.
///
/// Sentence count varies (2 or 3) depending on whether AirNow supplied a
/// specific reporting agency for this reading -- the agency-credit sentence
/// is the only optional one; the AirNow/EPA credit and the disclaimer are
/// never omitted.
struct AttributionAndDisclaimerText: View {
    let headline: PollutantReading

    var body: some View {
        Text(paragraph)
            .font(.caption2)
            // Fixed white, not adaptive `.secondary` -- both call sites
            // show this near the bottom of their content, over AppBrand's
            // darker gradient region.
            .foregroundStyle(.white.opacity(0.72))
            // Same truncation fix as `TimestampCaption`'s own doc comment
            // explains -- a `Text` constrained by the caller's fixed-width
            // frame truncates with an ellipsis instead of wrapping without
            // this, and this paragraph is the longest text block in either
            // panel.
            .fixedSize(horizontal: false, vertical: true)
    }

    private var paragraph: String {
        var sentences: [String] = []
        if let agencyCredit = headline.attributionText {
            sentences.append("\(agencyCredit).")
        }
        sentences.append("\(AttributionCopy.staticCredit).")
        sentences.append(AttributionCopy.preliminaryDataDisclaimer)
        return sentences.joined(separator: " ")
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
        // Fixed white, not adaptive `.primary` (bluegull-aqi-a22) -- this
        // control's only call site (SettingsView) shows it well below the
        // top row, over AppBrand's dark lower gradient. `.toggleStyle(.switch)`,
        // not the platform default `.checkbox` -- macOS's default Toggle
        // style outside a Form is a checkbox with a small dark checkmark
        // glyph, which Steve found hard to see against this background
        // (confirmed live, 2026-08-25). The pill switch has no glyph to
        // lose contrast, and its ON-state fill picks up this panel's own
        // `.tint(AppBrand.midBlue)` (SettingsView) instead.
        Toggle("Show AQI category color in menu bar", isOn: $isColorPillEnabled)
            .toggleStyle(.switch)
            .foregroundStyle(.white)
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
        // Fixed white + `.toggleStyle(.switch)`, not adaptive `.primary` +
        // the platform-default checkbox (bluegull-aqi-a22) -- same
        // reasoning as `MenuBarColorStyleToggle`'s own comment above.
        Toggle("Show \"AQI\" label in menu bar", isOn: $isAQILabelEnabled)
            .toggleStyle(.switch)
            .foregroundStyle(.white)
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
///
/// Also falls back to the same icon+dash treatment whenever `lastError` is
/// non-nil, even if `freshness` is still `.fresh` (bluegull-aqi-e70.37) --
/// found by Steve switching data source modes with the service down: the
/// cached reading was still within its TTL, so the number just sat there
/// unchanged with no indication the *active* source was currently failing.
/// Same "don't show a number I can't currently trust" reasoning as the
/// staleness fallback above, not a separate visual -- reusing it instead of
/// inventing a warning badge was Steve's own call once this gap was found.
struct MenuBarStatusLabel: View {
    let reading: AQIReading?
    let freshness: AQIFreshness?
    let lastError: AQIFetchError?

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
        if let reading, freshness == .fresh, lastError == nil,
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
