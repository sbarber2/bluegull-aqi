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

    var body: some View {
        Picker("Data Source", selection: $mode) {
            Text("Service (no setup required)").tag(DataSourceMode.service)
            Text("Direct (use my own AirNow key)").tag(DataSourceMode.direct)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("dataSourceModePicker")
    }
}
