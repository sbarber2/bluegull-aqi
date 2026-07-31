import SwiftUI
import WidgetKit
import BluegullAQIKit

/// Real per-family layouts (bluegull-aqi-mtm.4 small, mtm.5 medium, mtm.6
/// large). Lives in this separate `BluegullAQIWidgetViews` library target,
/// not the `BluegullAQIWidget` app-extension target itself, specifically so
/// an ImageRenderer harness/test target can import and render it directly
/// (bluegull-aqi-mtm.10) -- an app-extension build product can't be linked
/// by a separate target (see `WidgetTimelineComputer`'s own doc comment for
/// the confirmed build error this works around).
public struct BluegullAQIWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: BluegullAQIWidgetEntry

    // WidgetKit's own `\.widgetFamily` environment key is get-only (the
    // real widget host is the only thing allowed to set it) -- confirmed
    // against the SDK's own .swiftinterface, not assumed. A headless
    // renderer (bluegull-aqi-mtm.10's harness/tests) has no widget host to
    // inject it, so this override is the only way to force a specific
    // family outside one. nil (the normal widget-host path) defers to
    // whatever the environment actually provides.
    private let familyOverride: WidgetFamily?

    public init(entry: BluegullAQIWidgetEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    public var body: some View {
        Group {
            if let reading = entry.reading,
               let headline = reading.headlinePollutant,
               let aqi = headline.nowcastAQI,
               let category = headline.category {
                switch family {
                case .systemSmall:
                    SmallWidgetLayout(aqi: aqi, category: category)
                case .systemMedium:
                    MediumWidgetLayout(aqi: aqi, category: category, reading: reading, headline: headline)
                default:
                    LargeWidgetLayout(aqi: aqi, category: category, reading: reading)
                }
            } else {
                // Deliberately minimal -- distinguishing "never fetched" from
                // "cache expired" from "genuinely offline" is dc2.1's
                // dedicated scope, not this task's. This is just "nothing to
                // show yet."
                noDataView
            }
        }
        // Required since macOS 14/iOS 17 -- a widget that never calls this
        // gets no background fill from a headless renderer (confirmed via a
        // real bluegull-aqi-mtm.11 golden-image snapshot: dark-mode text
        // came out invisible, white-on-transparent, because nothing behind
        // it adapted to the color scheme). A real widget host has
        // historically papered over a missing containerBackground with an
        // automatic default, but relying on that is exactly the kind of
        // implicit behavior Apple's own WWDC23 guidance says to stop doing.
        .containerBackground(.background, for: .widget)
    }

    private var noDataView: some View {
        VStack(spacing: 4) {
            Image(systemName: "aqi.medium")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Data")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// bluegull-aqi-mtm.4: compact -- AQI number, official EPA category color,
/// descriptor. Nothing else fits `.systemSmall` legibly.
struct SmallWidgetLayout: View {
    let aqi: Int
    let category: AQICategory

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(category.color.swiftUIColor)
                .frame(width: 12, height: 12)
            Text("\(aqi)")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
            Text(category.descriptor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// bluegull-aqi-mtm.5: headline AQI plus "a few" other pollutants -- the two
/// highest-AQI entries besides the headline itself, so what's shown next to
/// the headline is "what else matters," using the same NowCast ranking
/// `headlinePollutant` itself uses, not an arbitrary subset.
struct MediumWidgetLayout: View {
    let aqi: Int
    let category: AQICategory
    let reading: AQIReading
    let headline: PollutantReading

    private var otherPollutants: [PollutantReading] {
        Array(
            reading.pollutants
                .filter { $0.parameterName != headline.parameterName && $0.nowcastAQI != nil }
                .sorted { ($0.nowcastAQI ?? 0) > ($1.nowcastAQI ?? 0) }
                .prefix(2)
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Circle()
                    .fill(category.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                Text("\(aqi)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(category.descriptor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !otherPollutants.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(otherPollutants, id: \.parameterName) { pollutant in
                        pollutantRow(pollutant)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private func pollutantRow(_ pollutant: PollutantReading) -> some View {
        HStack(spacing: 4) {
            Text(pollutant.parameterName)
                .font(.caption)
            if let pollutantAQI = pollutant.nowcastAQI, let pollutantCategory = pollutant.category {
                Text("\(pollutantAQI)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pollutantCategory.color.swiftUIColor)
            }
        }
    }
}

/// bluegull-aqi-mtm.6: full breakdown -- every pollutant AirNow returned,
/// same list shown in the menu bar popover (`AQIPopoverView`'s
/// `pollutantList`), since "full breakdown" means the same thing in both
/// places.
struct LargeWidgetLayout: View {
    let aqi: Int
    let category: AQICategory
    let reading: AQIReading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(category.color.swiftUIColor)
                    .frame(width: 12, height: 12)
                Text("\(aqi)")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text(category.descriptor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                // parameterName is unique within one AQIReading (see
                // PollutantReading's own doc comment).
                ForEach(reading.pollutants, id: \.parameterName) { pollutant in
                    pollutantRow(pollutant)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private func pollutantRow(_ pollutant: PollutantReading) -> some View {
        HStack {
            Text(PollutantCopy.spelledOutName(forParameterName: pollutant.parameterName))
                .font(.caption)
            Spacer()
            if let pollutantAQI = pollutant.nowcastAQI, let pollutantCategory = pollutant.category {
                Text("\(pollutantAQI)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pollutantCategory.color.swiftUIColor)
            } else {
                // Raw-concentration-only entry, no computed AQI supplied --
                // never invent one (bluegull-aqi-10h.17).
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
