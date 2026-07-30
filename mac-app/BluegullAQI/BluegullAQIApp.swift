import SwiftUI
import BluegullAQIKit

@main
struct BluegullAQIApp: App {
    // No real fetch pipeline exists yet (bluegull-aqi-e70.6/e70.7, not yet
    // implemented) -- starts nil, showing AQIPopoverView's empty state.
    @State private var latestReading: AQIReading?

    var body: some Scene {
        MenuBarExtra(NowCastCopy.headline, systemImage: "aqi.medium") {
            AQIPopoverView(reading: latestReading)
        }
        .menuBarExtraStyle(.window)
    }
}
