import SwiftUI
import BluegullAQIKit

/// The `.window`-style popover content shown when the menu bar status item
/// is clicked (bluegull-aqi-e70.11). A "dumb" presentational view -- takes
/// whatever reading it's given and renders it; wiring a real, live-fetched
/// `AQIReading` in is separate tracked work (bluegull-aqi-e70.6/e70.7), not
/// yet done. The preliminary-data disclaimer is deliberately NOT rendered
/// here -- separately tracked (bluegull-aqi-dc2.4) since its exact
/// wording/placement is a compliance call for Steve to make, not something
/// to invent here. Attribution IS rendered (bluegull-aqi-e70.10).
struct AQIPopoverView: View {
    let reading: AQIReading?

    // The "natural home for reaching settings" e70.11 anticipated but
    // deliberately didn't build -- added here as part of e70.9, which
    // needs an actual settings flow to drive with a UI test.
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsButton")
            }

            if let reading,
               let headline = reading.headlinePollutant,
               let aqi = headline.nowcastAQI,
               let category = headline.category {
                headlineSection(aqi: aqi, category: category)
                if let notice = category.beyondScaleNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                pollutantList(reading.pollutants)
                Divider()
                attributionFooter(headline)
            } else {
                ContentUnavailableView(
                    "No Air Quality Data",
                    systemImage: "aqi.medium",
                    description: Text("BlueGull AQI hasn't fetched a reading yet.")
                )
            }
        }
        .padding()
        .frame(width: 300)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private func headlineSection(aqi: Int, category: AQICategory) -> some View {
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

    private func pollutantList(_ pollutants: [PollutantReading]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // parameterName is unique within one AQIReading -- one array
            // entry per pollutant, per PollutantReading's own doc comment.
            ForEach(pollutants, id: \.parameterName) { pollutant in
                pollutantRow(pollutant)
            }
        }
    }

    private func pollutantRow(_ pollutant: PollutantReading) -> some View {
        HStack {
            Text(PollutantCopy.spelledOutName(forParameterName: pollutant.parameterName))
                .font(.body)
            Spacer()
            if let aqi = pollutant.nowcastAQI, let category = pollutant.category {
                Text("\(aqi)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(category.color.swiftUIColor)
            } else {
                // Raw-concentration-only entry, no computed AQI supplied --
                // never invent one (bluegull-aqi-10h.17).
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Two-tier attribution (bluegull-aqi-e70.10, bluegull-aqi-10h.15):
    /// credit the specific reporting agency for the headline reading first,
    /// when AirNow supplied one, then the static AirNow/EPA credit -- always
    /// shown, never omitted, styled after the airnow.gov precedent (a
    /// persistent small footer, not a Settings/About screen).
    private func attributionFooter(_ headline: PollutantReading) -> some View {
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
