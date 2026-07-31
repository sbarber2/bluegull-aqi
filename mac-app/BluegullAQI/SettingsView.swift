import SwiftUI

/// Composes the three settings pieces built separately
/// (`DataSourceModeToggle`, `bluegull-aqi-e70.3`; `AirNowAPIKeyEntryView`,
/// `e70.4`; `PinnedLocationsView`, `e70.5`) into one reachable destination
/// -- the integration each of those explicitly deferred as "not yet wired
/// into a settings window." Built as part of `bluegull-aqi-e70.9`, since a
/// UI test suite covering "settings flows" needs a settings flow that
/// actually exists to click through.
///
/// Hosted in its own `Window(id: "settings")` (`BluegullAQIApp`), not a
/// `.sheet()` -- see `AQIPopoverView`'s doc comment on why that didn't
/// work reliably. `dismissWindow`, not the sheet-specific `dismiss`
/// action, closes it.
///
/// Sizing: the window's own `.windowResizability(.contentSize)` is what
/// makes it fit this view's ideal size -- deliberately no `.fixedSize()`
/// here too. The two fighting over sizing authority is exactly what
/// triggered a real "already being laid out" AppKit recursion warning in
/// Steve's first interactive run of the `Window`-based version.
struct SettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismissWindow(id: "settings") }
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
