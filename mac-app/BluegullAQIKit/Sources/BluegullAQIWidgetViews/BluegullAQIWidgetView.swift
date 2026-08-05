import Foundation
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
                    SmallWidgetLayout(aqi: aqi, category: category, locationName: entry.locationName)
                case .systemMedium:
                    MediumWidgetLayout(aqi: aqi, category: category, reading: reading, headline: headline, locationName: entry.locationName)
                default:
                    LargeWidgetLayout(aqi: aqi, category: category, reading: reading, locationName: entry.locationName)
                }
            } else {
                // bluegull-aqi-dc2.1: distinguishes "never fetched" (no
                // reading, no successful fetch ever recorded -- fresh
                // install) from "went stale" (a fetch succeeded at some
                // point, but that entry's since expired and been swept,
                // bluegull-aqi-10h.12) -- rather than both collapsing to the
                // same unqualified "No Data."
                emptyStateView
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

    private var emptyStateView: some View {
        VStack(spacing: 4) {
            // So two "No Data" widgets pointed at different locations
            // (bluegull-aqi-mtm.20) don't look identical -- the whole
            // reason to distinguish them is moot if neither says which
            // location it's actually waiting on data for.
            Text(entry.locationName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "aqi.medium")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(emptyStateHeadline)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let staleCaption {
                Text(staleCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateHeadline: String {
        staleCaption == nil ? "No Data" : "Data Unavailable"
    }

    // Formatted relative to `entry.date` (the Timeline's own "now" at
    // render time), not the live wall clock -- WidgetKit's `Text(_:style:)`
    // live-relative formatting is meant for real-time UI and isn't
    // deterministic for this package's golden-image snapshot tests
    // (bluegull-aqi-mtm.11), which render well after `entry.date` and need
    // byte-stable output. `AQIPopoverView`'s menu bar equivalent uses the
    // live style instead -- that view has no such snapshot-determinism
    // constraint.
    private var staleCaption: String? {
        guard let lastSuccessfulFetchDate = entry.lastSuccessfulFetchDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let relative = formatter.localizedString(for: lastSuccessfulFetchDate, relativeTo: entry.date)
        return "Last updated \(relative)"
    }
}

/// bluegull-aqi-mtm.4: compact -- AQI number, official EPA category color,
/// descriptor. Nothing else fits `.systemSmall` legibly.
struct SmallWidgetLayout: View {
    // @ScaledMetric, not a bare .system(size:) point size, so the headline
    // number actually grows under Dynamic Type on a real widget host --
    // bluegull-aqi-mtm.17. Our ImageRenderer-based snapshot harness can't
    // verify this itself (confirmed: ImageRenderer doesn't honor
    // .environment(\.dynamicTypeSize, ...) at all, independent of this
    // code -- see that issue and bluegull-aqi-mtm.9's expanded scope).
    @ScaledMetric(relativeTo: .largeTitle) private var aqiFontSize: CGFloat = 36
    let aqi: Int
    let category: AQICategory
    let locationName: String

    var body: some View {
        VStack(spacing: 6) {
            // bluegull-aqi-mtm.20: every widget shows its own location now,
            // not just whichever one the menu bar happens to be showing --
            // this is what actually makes that visible.
            Text(locationName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Circle()
                .fill(category.color.swiftUIColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            Text("\(aqi)")
                .font(.system(size: aqiFontSize, weight: .semibold, design: .rounded))
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
    // See SmallWidgetLayout's doc comment for why @ScaledMetric, not a bare
    // .system(size:) point size.
    @ScaledMetric(relativeTo: .title) private var aqiFontSize: CGFloat = 30
    let aqi: Int
    let category: AQICategory
    let reading: AQIReading
    let headline: PollutantReading
    let locationName: String

    private var otherPollutants: [PollutantReading] {
        Array(
            reading.pollutants
                .filter { $0.parameterName != headline.parameterName && $0.nowcastAQI != nil }
                .sorted { ($0.nowcastAQI ?? 0) > ($1.nowcastAQI ?? 0) }
                .prefix(2)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // bluegull-aqi-mtm.20: every widget shows its own location now,
            // not just whichever one the menu bar happens to be showing.
            Text(locationName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Circle()
                        .fill(category.color.swiftUIColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
                    Text("\(aqi)")
                        .font(.system(size: aqiFontSize, weight: .semibold, design: .rounded))
                    // Otherwise the headline number is unlabeled: otherPollutants
                    // deliberately excludes the headline itself from the side
                    // list below (bluegull-aqi-0u4), so without this the widget
                    // can read as if only the *other* pollutant exists at all --
                    // confirmed against a real reading where the headline was
                    // PM2.5 and the only visible name on screen was "OZONE."
                    Text(headline.parameterName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        .padding()
    }

    private func pollutantRow(_ pollutant: PollutantReading) -> some View {
        HStack(spacing: 4) {
            Text(pollutant.parameterName)
                .font(.caption)
            if let pollutantAQI = pollutant.nowcastAQI, let pollutantCategory = pollutant.category {
                // See LargeWidgetLayout's own pollutantRow for why this is
                // a colored background + contrasting text, not colored
                // text (bluegull-aqi-mtm.19).
                Text("\(pollutantAQI)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pollutantCategory.color.contrastingTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pollutantCategory.color.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// bluegull-aqi-mtm.6: full breakdown -- every pollutant AirNow returned,
/// same list shown in the menu bar popover (`AQIPopoverView`'s
/// `pollutantList`), since "full breakdown" means the same thing in both
/// places.
struct LargeWidgetLayout: View {
    // See SmallWidgetLayout's doc comment for why @ScaledMetric, not a bare
    // .system(size:) point size.
    @ScaledMetric(relativeTo: .title) private var aqiFontSize: CGFloat = 32
    let aqi: Int
    let category: AQICategory
    let reading: AQIReading
    let locationName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // bluegull-aqi-mtm.20: every widget shows its own location now,
            // not just whichever one the menu bar happens to be showing.
            Text(locationName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(category.color.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                Text("\(aqi)")
                    .font(.system(size: aqiFontSize, weight: .semibold, design: .rounded))
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
                // Colored background + black/white contrasting text, not
                // colored text on the widget's plain background -- plain-
                // colored text had poor contrast for the lighter
                // categories (Good/Moderate/USG), found by Steve against
                // AirNow's own AQI Legend panel styling
                // (bluegull-aqi-mtm.19).
                Text("\(pollutantAQI)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pollutantCategory.color.contrastingTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pollutantCategory.color.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
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
