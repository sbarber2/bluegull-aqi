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

    var body: some View {
        if let reading, freshness == .fresh,
           let headline = reading.headlinePollutant,
           let aqi = headline.nowcastAQI, let category = headline.category {
            HStack(spacing: 4) {
                Circle()
                    .fill(category.color.swiftUIColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                Text("\(aqi)")
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
}
