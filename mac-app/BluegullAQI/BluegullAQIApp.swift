import SwiftUI
import BluegullAQIKit

@main
struct BluegullAQIApp: App {
    // Drives the actual fetch loop (bluegull-aqi-e70.6/e70.7) -- nil only
    // if the App Group suite couldn't be opened, in which case the popover
    // falls back to its empty state permanently, the same as before this
    // existed.
    @State private var refreshController = AQIRefreshController()

    // Requesting on launch is a minimal, real trigger point -- `@State`'s
    // initial value is created exactly once per app launch, so this fires
    // the request (if needed) once, not on every scene rebuild.
    @State private var locationPermission = LocationPermissionRequester(requestOnInit: true)

    // Set from the incoming widgetURL when the widget's tap target opens
    // the detail window (bluegull-aqi-mtm.14) -- nil until then, which
    // WidgetDetailView already treats as "current location"/most-recently-
    // cached, the same fallback the widget itself uses.
    @State private var widgetDetailLocation: Location?

    var body: some Scene {
        MenuBarExtra {
            AQIPopoverView(reading: refreshController?.latestReading)
                .task { refreshController?.start() }
                // Fetch immediately once permission is actually granted,
                // rather than waiting for the scheduled loop's first
                // (possibly-too-early) attempt to eventually get retried
                // up to an hour later.
                .onChange(of: locationPermission.authorizationStatus) {
                    Task { await refreshController?.refreshNow() }
                }
        } label: {
            MenuBarStatusLabel(reading: refreshController?.latestReading)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "widget-detail") {
            WidgetDetailView(location: widgetDetailLocation)
                .onOpenURL { url in
                    widgetDetailLocation = WidgetDeepLink.location(from: url)
                }
        }
        .windowResizability(.contentSize)

        // A real singleton window, not a .sheet() over the MenuBarExtra
        // popover -- see AQIPopoverView's doc comment for why. .contentSize
        // resizability + SettingsView's own .fixedSize(vertical: true) are
        // what actually fix the cropping that was visible under the old
        // sheet presentation.
        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
