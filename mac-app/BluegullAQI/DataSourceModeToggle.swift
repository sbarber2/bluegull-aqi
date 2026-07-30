import SwiftUI
import BluegullAQIKit

/// Lets the user switch between Service mode (default) and Direct mode
/// (bluegull-aqi-e70.3). `@AppStorage` keyed off `DataSourceModeStore`'s own
/// constants rather than a duplicated string literal, so this and whatever
/// eventually reads the setting to decide which client to call
/// (bluegull-aqi-e70.6) can't disagree on the key or default.
///
/// A self-contained component, not yet wired into a settings destination --
/// there isn't one yet (no gear icon/sheet exists; see
/// `AQIPopoverView`'s own doc comment). `e70.4`/`e70.5` will each produce
/// their own similarly self-contained piece; composing them into one
/// settings screen is separate, not-yet-tracked integration work.
struct DataSourceModeToggle: View {
    @AppStorage(DataSourceModeStore.userDefaultsKey) private var mode: DataSourceMode = DataSourceModeStore.defaultMode

    var body: some View {
        Picker("Data Source", selection: $mode) {
            Text("Service (no setup required)").tag(DataSourceMode.service)
            Text("Direct (use my own AirNow key)").tag(DataSourceMode.direct)
        }
        .pickerStyle(.segmented)
    }
}
