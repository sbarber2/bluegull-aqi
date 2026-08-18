import SwiftUI
import BluegullAQIKit

/// Lets the user switch between Service mode (default) and Direct mode
/// (bluegull-aqi-e70.3). `@AppStorage` keyed off `DataSourceModeStore`'s own
/// constants rather than a duplicated string literal, so this and whatever
/// eventually reads the setting to decide which client to call
/// (bluegull-aqi-e70.6) can't disagree on the key or default.
///
/// Composed into `SettingsView` (bluegull-aqi-e70.9), reachable via
/// `AQIPopoverView`'s gear icon.
struct DataSourceModeToggle: View {
    // `store:` the App Group suite, not the default `UserDefaults.standard`
    // (bluegull-aqi-mtm.24) -- the widget extension fetches for itself now
    // and has to read the same selection this writes. See
    // `DataSourceModeStore`'s own doc comment.
    @AppStorage(DataSourceModeStore.userDefaultsKey, store: DataSourceModeStore.sharedDefaults)
    private var mode: DataSourceMode = DataSourceModeStore.defaultMode

    // Called after the mode changes, so the caller (BluegullAQIApp) can
    // trigger an immediate refetch under the newly selected source rather
    // than leaving whatever was last fetched under the old mode showing
    // until the next scheduled refresh, up to an hour away -- same
    // "hygiene" reasoning, and the same pattern, as
    // `MenuBarLocationPicker.onChange` (bluegull-aqi-e70.21). Without this,
    // switching Direct<->Service silently kept showing stale data, which
    // is exactly what Steve hit and reported before (see AQIPopoverView's
    // own doc comment on bluegull-aqi-dc2.1's origin).
    let onChange: () -> Void

    var body: some View {
        Picker("Data Source", selection: $mode) {
            Text("Service (no setup required)").tag(DataSourceMode.service)
            Text("Direct (use my own AirNow key)").tag(DataSourceMode.direct)
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { onChange() }
        .accessibilityIdentifier("dataSourceModePicker")
    }
}
