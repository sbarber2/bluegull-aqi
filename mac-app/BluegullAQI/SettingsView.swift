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
///
/// `.frame(width: 360)` (a single fixed value) was a second, separate
/// sizing bug: `.windowResizability(.contentSize)` derives the window's
/// resizable range directly from the content's reported size range, and a
/// single fixed width reports min == ideal == max -- the window genuinely
/// could not be resized horizontally, and 360pt already truncated
/// DataSourceModeToggle's longer segmented-control labels besides. A real
/// min/ideal range, not a fixed value, is what makes the window both wide
/// enough by default and actually draggable-resizable.
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
        .frame(minWidth: 420, idealWidth: 460)
        .accessibilityIdentifier("settingsView")
    }
}
