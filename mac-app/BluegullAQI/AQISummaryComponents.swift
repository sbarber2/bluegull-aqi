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
