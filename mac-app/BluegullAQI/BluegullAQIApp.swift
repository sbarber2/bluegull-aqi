import AppKit
import SwiftUI
import BluegullAQIKit

@main
struct BluegullAQIApp: App {
    // True when XCTest is hosting this process, not a real launch --
    // `BluegullAQITests` needs a *running* app as its test host
    // (TEST_HOST/BUNDLE_LOADER), which means this exact struct's `init()`/
    // `@State` initializers run for real under `make test-swift` unless
    // guarded. Found because they weren't: every test-swift run re-fired
    // the real Location permission dialog (test-swift builds with
    // CODE_SIGNING_ALLOWED=NO, so TCC sees an unrecognized identity each
    // time and treats it as undecided) and started a real
    // AQIRefreshController fetch loop hitting CoreLocation/the network --
    // and if a real signed instance happened to already be running, the
    // single-instance flock below saw it, exited immediately, and failed
    // the whole test run ("Early unexpected exit"), confirmed as a real
    // failure earlier in this project's history, not a hypothetical.
    // `XCTestConfigurationFilePath` is the standard env var XCTest sets on
    // whatever process it's hosting inside, regardless of which specific
    // test bundle is running.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // Drives the actual fetch loop (bluegull-aqi-e70.6/e70.7) -- nil if the
    // App Group suite couldn't be opened (the popover falls back to its
    // empty state permanently, same as before this existed) or if
    // `isRunningTests` (bluegull-aqi-o4b's test-swift investigation) --
    // `AQIRefreshController.init?` already models "nothing to drive the
    // popover with" as nil, so this reuses that instead of a separate flag.
    @State private var refreshController = isRunningTests ? nil : AQIRefreshController()

    // Requesting on launch is a minimal, real trigger point -- `@State`'s
    // initial value is created exactly once per app launch, so this fires
    // the request (if needed) once, not on every scene rebuild.
    // `requestOnInit: !isRunningTests` -- see `isRunningTests`'s own doc
    // comment; `LocationPermissionRequester` already supports this exact
    // no-op mode for previews, tests just needed to actually opt into it.
    @State private var locationPermission = LocationPermissionRequester(requestOnInit: !isRunningTests)

    // Set from the incoming widgetURL when the widget's tap target opens
    // the detail window (bluegull-aqi-mtm.14) -- nil until then, which
    // WidgetDetailView already treats as "current location"/most-recently-
    // cached, the same fallback the widget itself uses.
    @State private var widgetDetailLocation: Location?

    // Single-instance guard (bluegull-aqi-e70.25): macOS's usual "activate
    // the existing instance instead of relaunching" behavior is a
    // LaunchServices convenience, not something SwiftUI/AppKit enforces on
    // its own -- and it's bypassed by whatever launch path the desktop
    // widget gallery uses to start this app, producing a second MenuBarExtra
    // icon. This runs in `init()`, before `body` is ever evaluated and
    // therefore before the MenuBarExtra scene can build.
    //
    // An earlier version of this guard just listed
    // NSRunningApplication.runningApplications and activated/exited based
    // on what it found -- a check-then-act race: two launch attempts close
    // together (e.g. placing two widgets back-to-back) could both run the
    // check before either was visible to the other, so both survived.
    // `flock` on a file in the App Group container is atomic at the kernel
    // level instead -- no gap between "check" and "act" for two processes
    // to race through. The fd is deliberately never closed: held for the
    // process's whole lifetime, released automatically (and crash-safely,
    // no stale-lock cleanup needed) when the process exits. `exit(0)`, not
    // `NSApp.terminate`, because AppKit's own lifecycle isn't fully spun up
    // yet this early, so terminate risks the menu bar item flashing into
    // existence first.
    init() {
        // See `isRunningTests`'s own doc comment -- without this, the test
        // host process races the real single-instance lock and exits
        // immediately whenever a real signed instance is already running.
        guard !Self.isRunningTests else { return }
        // bluegull-aqi-8iz: BEFORE the Settings Window scene (below) ever
        // gets a chance to create its NSWindow and restore a saved frame
        // into it -- see `SettingsWindowFrameSanitizer`'s own doc comment
        // for why this specific ordering (launch-time, not the window's
        // own `.onAppear`) is what avoids a visible flash of the old,
        // oversized layout for anyone upgrading from a version installed
        // before the Settings redesign (bluegull-aqi-a22).
        SettingsWindowFrameSanitizer.scrubIfStale()
        // Before anything reads the mode (the fetch loop starts as soon as
        // `refreshController` is constructed, just below) -- moves a
        // pre-existing Direct-mode choice out of UserDefaults.standard,
        // where this setting lived before the widget needed to read it too
        // (bluegull-aqi-mtm.24). No-op after the first launch.
        DataSourceModeStore.migrateFromStandardIfNeeded()
        let lockURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: UserDefaultsCacheStore.appGroupIdentifier)!
            .appendingPathComponent("instance.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        if fd == -1 || flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Someone else already holds the lock -- best-effort bring them
            // forward (purely a UX nicety; the lock above is what actually
            // decides who survives), then get out of the way.
            let bundleID = Bundle.main.bundleIdentifier!
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
            exit(0)
        }
    }

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
            MenuBarStatusLabel(
                reading: refreshController?.latestReading,
                freshness: refreshController?.latestReadingFreshness,
                lastError: refreshController?.lastError
            )
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
            WidgetDetailView(location: widgetDetailLocation, refreshController: refreshController)
                .onOpenURL { url in
                    widgetDetailLocation = WidgetDeepLink.location(from: url)
                }
                // bluegull-aqi-e70.52: without this, the window keeps its
                // default light-chrome title bar (dark title text,
                // assuming a light content area below it) while
                // WidgetDetailView's own content is now AppBrand's dark
                // gradient -- found live, Steve: "black on something very
                // dark." `.preferredColorScheme` on a Window scene's root
                // view propagates to the whole NSWindow's appearance on
                // macOS, not just this view's own SwiftUI environment, so
                // it also switches the title bar to dark styling (light
                // title text) to match.
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        // A real singleton window, not a .sheet() over the MenuBarExtra
        // popover -- see AQIPopoverView's doc comment for why.
        // .windowResizability(.contentSize) alone sizes it to
        // SettingsView's content; deliberately no additional .fixedSize()
        // there too (see that file's own doc comment on the layout-
        // recursion bug that combination caused).
        Window("Settings", id: "settings") {
            // bluegull-aqi-a22 originally left this OUT (unlike the
            // detail window's own, bluegull-aqi-e70.52) -- confirmed live
            // back then, forcing it pushed every embedded AppKit control
            // (the TextFields in PinnedLocationsView/AirNowAPIKeyEntryView
            // especially, still `.textFieldStyle(.roundedBorder)` at the
            // time) into dark-appearance rendering, meaning near-black
            // text field backgrounds jarring against the gradient.
            //
            // bluegull-aqi-as9: re-added. That original reason no longer
            // applies -- every text/secure field in Settings now uses
            // `brandFieldStyle()` (`.textFieldStyle(.plain)` plus a
            // custom-drawn background), not the system's own light/dark-
            // adaptive chrome, so there's nothing left for a forced dark
            // appearance to darken unpleasantly. And it's needed now:
            // Settings dropped the gradient for a flat, uniformly dark
            // `AppBrand.settingsBackground` (that same bead), which is
            // dark all the way to the very top -- without this, the
            // window keeps its default light-chrome title bar (dark
            // title text) over that dark content, the same illegible
            // dark-on-dark WidgetDetailView itself had before its own fix.
            SettingsView(onDataSourceModeChange: { Task { await refreshController?.refreshNow() } })
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        // bluegull-aqi-a22: belt-and-suspenders alongside
        // `.windowResizability(.contentSize)` -- confirmed live, Steve,
        // 2026-08-25: this window's own `NSWindow Frame settings`
        // AppKit frame-autosave entry (keyed by this Window's `id`, same
        // mechanism as `widget-detail`'s own, see `WidgetDetailView`'s
        // doc comment) had gotten stuck at 1106pt wide from a much older
        // session, and every later `SettingsView` sizing change was
        // silently masked by AppKit restoring that old frame on launch
        // regardless of what `.windowResizability(.contentSize)` computed
        // from content (verified directly: `ImageRenderer` measuring
        // `SettingsView` in isolation reported exactly the intended
        // 400pt-wide ideal size the whole time -- the SwiftUI layout was
        // never the problem). No SwiftUI API disables that autosave
        // outright; `.defaultSize` doesn't override an *existing* saved
        // frame either, but gives a same explicit fallback for the
        // literal first-ever launch (no saved frame yet at all), so a
        // fresh install doesn't depend on `.windowResizability` alone.
        .defaultSize(width: 400, height: 620)
        // bluegull-aqi-a22: a SECOND, distinct real bug found live,
        // Steve, 2026-08-25 -- not the width/truncation issue above.
        // Once Direct mode + several Pinned Locations rows pushed this
        // window's content taller than its previously-saved frame, the
        // saved frame's position (its BOTTOM edge, in AppKit's bottom-up
        // coordinates) stayed fixed while the window grew upward to fit
        // the new height, pushing most of the window off the TOP of the
        // screen -- Steve saw only a one-row sliver ("the first pinned
        // location is only half-shown... where are the other 9"), not a
        // squeezed-but-fully-visible list. `.defaultPosition(.center)`
        // only applies with no saved position yet (same one-time-fallback
        // caveat as `.defaultSize` above), but keeps a *future* content
        // growth spike from repeating this off-screen-until-manually-
        // cleared failure for a fresh install that's never opened this
        // window before.
        .defaultPosition(.center)
    }
}
