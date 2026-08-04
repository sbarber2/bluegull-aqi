import SwiftUI
import BluegullAQIKit

/// The full per-pollutant breakdown -- originally private to
/// `AQIPopoverView` (bluegull-aqi-e70.11), extracted here once
/// `WidgetDetailView` needed the identical content (bluegull-aqi-mtm.15's
/// pollutant-breakdown slice, pulled forward from its original POST-v1
/// deferral once Steve decided the detail view "may as well" show it, the
/// same as the popover already does and `LargeWidgetLayout` already does
/// on the widget face itself).
struct PollutantListView: View {
    let pollutants: [PollutantReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // parameterName is unique within one AQIReading -- one array
            // entry per pollutant, per PollutantReading's own doc comment.
            ForEach(pollutants, id: \.parameterName) { pollutant in
                row(pollutant)
            }
        }
    }

    private func row(_ pollutant: PollutantReading) -> some View {
        HStack {
            Text(PollutantCopy.spelledOutName(forParameterName: pollutant.parameterName))
                .font(.body)
            Spacer()
            if let aqi = pollutant.nowcastAQI, let category = pollutant.category {
                // Colored background + contrasting text, not colored text
                // on the plain background -- same contrast fix as
                // LargeWidgetLayout/MediumWidgetLayout (bluegull-aqi-mtm.19).
                Text("\(aqi)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(category.color.contrastingTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(category.color.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
            } else {
                // Raw-concentration-only entry, no computed AQI supplied --
                // never invent one (bluegull-aqi-10h.17).
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
