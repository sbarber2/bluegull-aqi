import SwiftUI

/// Composes the three settings pieces built separately
/// (`DataSourceModeToggle`, `bluegull-aqi-e70.3`; `AirNowAPIKeyEntryView`,
/// `e70.4`; `PinnedLocationsView`, `e70.5`) into one reachable destination
/// -- the integration each of those explicitly deferred as "not yet wired
/// into a settings window." Built as part of `bluegull-aqi-e70.9`, since a
/// UI test suite covering "settings flows" needs a settings flow that
/// actually exists to click through.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("settingsDoneButton")
            }

            DataSourceModeToggle()
            Divider()
            AirNowAPIKeyEntryView()
            Divider()
            PinnedLocationsView()
        }
        .padding()
        .frame(width: 360)
        .accessibilityIdentifier("settingsView")
    }
}
