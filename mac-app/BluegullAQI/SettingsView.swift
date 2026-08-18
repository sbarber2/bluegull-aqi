import SwiftUI
import BluegullAQIKit

/// Composes the three settings pieces built separately
/// (`DataSourceModeToggle`, `bluegull-aqi-e70.3`; `AirNowAPIKeyEntryView`,
/// `e70.4`; `PinnedLocationsView`, `e70.5`) into one reachable destination
/// -- the integration each of those explicitly deferred as "not yet wired
/// into a settings window." Built as part of `bluegull-aqi-e70.9`, since a
/// UI test suite covering "settings flows" needs a settings flow that
/// actually exists to click through.
///
/// `DataSourceModeToggle` doubles as a tab selector as of
/// bluegull-aqi-e70.43: once Service mode grew its own setting (the
/// configurable request timeout, alongside Direct mode's existing API key
/// + its own timeout), showing both sources' config at once stopped making
/// sense -- only the selected source's section renders below the toggle.
/// This view keeps its own `mode` binding (same key/store as
/// `DataSourceModeToggle`'s own, deliberately independent rather than
/// threaded through as a binding parameter -- matches this codebase's
/// existing precedent of multiple views each reading the same `@AppStorage`
/// key directly, e.g. `MenuBarStatusLabel`/`MenuBarColorStyleToggle` both
/// reading `MenuBarAppearanceStore.colorPillEnabledKey`).
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

    // bluegull-aqi-e70.28: Option-clicking the title reveals the hidden
    // dev-only backend URL override below -- not a supported/shipping
    // feature, so it's deliberately not behind an ordinary visible control.
    @State private var isDevOverrideRevealed = false

    // Forwarded straight to DataSourceModeToggle's own `onChange` -- see
    // that property's doc comment. Defaults to a no-op so render tests
    // (and any other caller with no refresh loop to trigger) don't need to
    // supply one.
    var onDataSourceModeChange: () -> Void = {}

    // bluegull-aqi-e70.43: decides which mode's config section to show
    // below the toggle -- see this type's own doc comment on why this is a
    // second, independent binding rather than one threaded down from
    // DataSourceModeToggle.
    @AppStorage(DataSourceModeStore.userDefaultsKey, store: DataSourceModeStore.sharedDefaults)
    private var mode: DataSourceMode = DataSourceModeStore.defaultMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                    .gesture(TapGesture().modifiers(.option).onEnded { isDevOverrideRevealed.toggle() })
                Spacer()
                Button("Done") { dismissWindow(id: "settings") }
                    .accessibilityIdentifier("settingsDoneButton")
            }

            DataSourceModeToggle(onChange: onDataSourceModeChange)

            // bluegull-aqi-e70.43: only the selected source's own section,
            // tab-style -- see this type's own doc comment.
            switch mode {
            case .direct:
                AirNowAPIKeyEntryView()
                DirectTimeoutStepper()
            case .service:
                Text("Service uses BlueGull's shared backend -- no API key needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ServiceTimeoutStepper()
            }

            Divider()
            PinnedLocationsView()
            Divider()
            MenuBarColorStyleToggle()
            MenuBarAQILabelToggle()

            if isDevOverrideRevealed {
                Divider()
                DevServiceURLOverrideView()
            }

            Divider()
            // bluegull-aqi-fw4.9: which exact build this is -- three
            // ad-hoc DMGs went out to a tester all labeled "1.0" before
            // this existed, indistinguishable from each other.
            Text(AppVersionInfo.current)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("appVersionLabel")
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 460)
        .accessibilityIdentifier("settingsView")
    }
}
