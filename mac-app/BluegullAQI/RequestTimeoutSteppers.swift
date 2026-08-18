import SwiftUI
import BluegullAQIKit

/// Per-data-source configurable request timeout (bluegull-aqi-e70.43) --
/// found the hard way: "we've exceeded our client response timeout to the
/// lambda on cold starts on occasion." Two separate structs, not one
/// parameterized over the mode, matching this file's own precedent
/// elsewhere in Settings (`MenuBarColorStyleToggle`/`MenuBarAQILabelToggle`)
/// of one small struct per control -- there are only ever two call sites,
/// each shown under its own tab in `SettingsView`, never both at once.
struct ServiceTimeoutStepper: View {
    @AppStorage(RequestTimeoutStore.serviceUserDefaultsKey, store: RequestTimeoutStore.sharedDefaults)
    private var timeoutSeconds: Double = RequestTimeoutStore.defaultServiceTimeout

    var body: some View {
        Stepper(
            "Timeout: \(Int(timeoutSeconds))s",
            value: $timeoutSeconds,
            in: RequestTimeoutStore.minimumTimeout...RequestTimeoutStore.maximumTimeout,
            step: 5
        )
        .accessibilityIdentifier("serviceTimeoutStepper")
    }
}

struct DirectTimeoutStepper: View {
    @AppStorage(RequestTimeoutStore.directUserDefaultsKey, store: RequestTimeoutStore.sharedDefaults)
    private var timeoutSeconds: Double = RequestTimeoutStore.defaultDirectTimeout

    var body: some View {
        Stepper(
            "Timeout: \(Int(timeoutSeconds))s",
            value: $timeoutSeconds,
            in: RequestTimeoutStore.minimumTimeout...RequestTimeoutStore.maximumTimeout,
            step: 5
        )
        .accessibilityIdentifier("directTimeoutStepper")
    }
}
