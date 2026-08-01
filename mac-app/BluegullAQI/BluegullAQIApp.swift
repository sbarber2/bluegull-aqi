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
            AQIPopoverView(
                reading: refreshController?.latestReading,
                lastError: refreshController?.lastError,
                lastFetchedAt: refreshController?.lastFetchedAt,
                onLocationChange: { Task { await refreshController?.refreshNow() } }
            )
        } label: {
            // .task/.onChange live here, not on AQIPopoverView above --
            // this label is always rendered (it's the menu bar item
            // itself), unlike the popover's content, which SwiftUI only
            // builds the first time the user actually clicks it. The fetch
            // loop used to start from a .task on the popover content,
            // which meant the menu bar showed no AQI value at all until
            // after a first click -- found by Steve in a real run. Now
            // AQIRefreshController starts itself at construction
            // (startOnInit), so this .task is just a safety net if that
            // somehow didn't fire; the .onChange retry genuinely does need
            // to live somewhere always-rendered, so it's here regardless.
            MenuBarStatusLabel(reading: refreshController?.latestReading)
                .task { refreshController?.start() }
                // Fetch immediately once permission is actually granted,
                // rather than waiting for the scheduled loop's first
                // (possibly-too-early) attempt to eventually get retried
                // up to an hour later.
                .onChange(of: locationPermission.authorizationStatus) {
                    Task { await refreshController?.refreshNow() }
                }
        }
        .menuBarExtraStyle(.window)

        // Window, NOT WindowGroup -- a WindowGroup without a `for:` data
        // binding is SwiftUI's "main content window" pattern, and macOS
        // auto-opens ONE instance of it at launch whether or not anything
        // ever requests it. That's a real bug this shipped with: an
        // unwanted widget-detail window (showing whatever was last cached,
        // including attribution/disclaimer) was silently open before the
        // user ever tapped the widget, and very likely holding focus in
        // front of the Settings window when the gear button tried to open
        // it -- found by Steve in a real run ("clicking the gear brought
        // up the AQI detail panel instead of Settings, and I could never
        // reach Settings at all"). `Window` is a true singleton and does
        // not auto-present -- matches how Settings itself is already
        // declared below.
        Window("Air Quality Detail", id: "widget-detail") {
            WidgetDetailView(location: widgetDetailLocation)
                .onOpenURL { url in
                    widgetDetailLocation = WidgetDeepLink.location(from: url)
                }
        }
        .windowResizability(.contentSize)

        // A real singleton window, not a .sheet() over the MenuBarExtra
        // popover -- see AQIPopoverView's doc comment for why.
        // .windowResizability(.contentSize) alone sizes it to
        // SettingsView's content; deliberately no additional .fixedSize()
        // there too (see that file's own doc comment on the layout-
        // recursion bug that combination caused).
        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
