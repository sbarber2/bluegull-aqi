import SwiftUI
import BluegullAQIKit

/// Real per-family layouts (bluegull-aqi-mtm.4 small, mtm.5 medium, mtm.6
/// large), replacing the `Text(NowCastCopy.headline)` placeholder
/// mtm.1/mtm.2/mtm.3 deliberately left in place while the timeline plumbing
/// was being built. `entry.reading` already flows from the App Group cache
/// via `WidgetTimelineComputer`, respecting the widget's configured
/// location (mtm.2/mtm.3) -- this type's only job is rendering it.
struct BluegullAQIWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BluegullAQIWidgetEntry

    var body: some View {
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
            // "cache expired" from "genuinely offline" is dc2.1's dedicated
            // scope, not this task's. This is just "nothing to show yet."
            noDataView
        }
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
private struct SmallWidgetLayout: View {
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
private struct MediumWidgetLayout: View {
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
private struct LargeWidgetLayout: View {
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
