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
        // Fixed white, not adaptive `.primary` (bluegull-aqi-a22) -- this
        // control's only call site (SettingsView) shows it well below the
        // top row, over AppBrand's dark lower gradient.
        Stepper(
            "Timeout: \(Int(timeoutSeconds))s",
            value: $timeoutSeconds,
            in: RequestTimeoutStore.minimumTimeout...RequestTimeoutStore.maximumTimeout,
            step: 5
        )
        .foregroundStyle(.white)
        .accessibilityIdentifier("serviceTimeoutStepper")
    }
}

struct DirectTimeoutStepper: View {
    @AppStorage(RequestTimeoutStore.directUserDefaultsKey, store: RequestTimeoutStore.sharedDefaults)
    private var timeoutSeconds: Double = RequestTimeoutStore.defaultDirectTimeout

    var body: some View {
        // Fixed white, not adaptive `.primary` (bluegull-aqi-a22) -- same
        // reasoning as `ServiceTimeoutStepper`'s own comment above.
        Stepper(
            "Timeout: \(Int(timeoutSeconds))s",
            value: $timeoutSeconds,
            in: RequestTimeoutStore.minimumTimeout...RequestTimeoutStore.maximumTimeout,
            step: 5
        )
        .foregroundStyle(.white)
        .accessibilityIdentifier("directTimeoutStepper")
    }
}
