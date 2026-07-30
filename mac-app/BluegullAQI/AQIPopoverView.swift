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
                AQIHeadlineBadge(aqi: aqi, category: category)
                if let notice = category.beyondScaleNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                pollutantList(reading.pollutants)
                Divider()
                AttributionFooter(headline: headline)
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

}
