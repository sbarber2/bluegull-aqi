import SwiftUI
import BluegullAQIKit

@main
struct BluegullAQIApp: App {
    // No real fetch pipeline exists yet (bluegull-aqi-e70.6/e70.7, not yet
    // implemented) -- starts nil, showing AQIPopoverView's empty state.
    @State private var latestReading: AQIReading?

    // Requesting on launch is a minimal, real trigger point -- deciding
    // exactly when/whether to request based on data-source or location
    // mode (e.g. skip entirely for a user who only ever pins addresses) is
    // e70.6's orchestration job, which depends on this existing at all.
    // `@State`'s initial value is created exactly once per app launch, so
    // this fires the request (if needed) once, not on every scene rebuild.
    @State private var locationPermission = LocationPermissionRequester(requestOnInit: true)

    // Set from the incoming widgetURL when the widget's tap target opens
    // the detail window (bluegull-aqi-mtm.14) -- nil until then, which
    // WidgetDetailView already treats as "current location"/most-recently-
    // cached, the same fallback the widget itself uses.
    @State private var widgetDetailLocation: Location?

    var body: some Scene {
        MenuBarExtra(NowCastCopy.headline, systemImage: "aqi.medium") {
            AQIPopoverView(reading: latestReading)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "widget-detail") {
            WidgetDetailView(location: widgetDetailLocation)
                .onOpenURL { url in
                    widgetDetailLocation = WidgetDeepLink.location(from: url)
                }
        }
        .windowResizability(.contentSize)
    }
}
