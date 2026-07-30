import SwiftUI
import BluegullAQIKit

@main
struct BluegullAQIApp: App {
    var body: some Scene {
        MenuBarExtra(NowCastCopy.headline, systemImage: "aqi.medium") {
            Text(NowCastCopy.headline)
        }
        .menuBarExtraStyle(.window)
    }
}
