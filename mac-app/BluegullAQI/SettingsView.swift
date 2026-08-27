import AppKit
import SwiftUI
import BluegullAQIKit

/// Composes the three settings pieces built separately
/// (`DataSourceModeToggle`, `bluegull-aqi-e70.3`; `AirNowAPIKeyEntryView`,
/// `e70.4`; `PinnedLocationsView`, `e70.5`) into one reachable destination
/// -- the integration each of those explicitly deferred as "not yet wired
/// into a settings window." Built as part of `bluegull-aqi-e70.9`, since a
/// UI test suite covering "settings flows" needs a settings flow that
/// actually exists to click through.
///
/// `DataSourceModeToggle` doubles as a tab selector as of
/// bluegull-aqi-e70.43: once Service mode grew its own setting (the
/// configurable request timeout, alongside Direct mode's existing API key
/// + its own timeout), showing both sources' config at once stopped making
/// sense -- only the selected source's section renders below the toggle.
/// This view keeps its own `mode` binding (same key/store as
/// `DataSourceModeToggle`'s own, deliberately independent rather than
/// threaded through as a binding parameter -- matches this codebase's
/// existing precedent of multiple views each reading the same `@AppStorage`
/// key directly, e.g. `MenuBarStatusLabel`/`MenuBarColorStyleToggle` both
/// reading `MenuBarAppearanceStore.colorPillEnabledKey`).
///
/// Hosted in its own `Window(id: "settings")` (`BluegullAQIApp`), not a
/// `.sheet()` -- see `AQIPopoverView`'s doc comment on why that didn't
/// work reliably. `dismissWindow`, not the sheet-specific `dismiss`
/// action, closes it.
///
/// Sizing: the window's own `.windowResizability(.contentSize)` is what
/// makes it fit this view's ideal size -- deliberately no `.fixedSize()`
/// here too. The two fighting over sizing authority is exactly what
/// triggered a real "already being laid out" AppKit recursion warning in
/// Steve's first interactive run of the `Window`-based version.
///
/// `.frame(width: 360)` (a single fixed value) was a second, separate
/// sizing bug: `.windowResizability(.contentSize)` derives the window's
/// resizable range directly from the content's reported size range, and a
/// single fixed width reports min == ideal == max -- the window genuinely
/// could not be resized horizontally, and 360pt already truncated
/// DataSourceModeToggle's longer segmented-control labels besides. A real
/// min/ideal range, not a fixed value, is what makes the window both wide
/// enough by default and actually draggable-resizable.
struct SettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    // bluegull-aqi-e70.28: Option-clicking the title reveals the hidden
    // dev-only backend URL override below -- not a supported/shipping
    // feature, so it's deliberately not behind an ordinary visible control.
    @State private var isDevOverrideRevealed = false

    // Forwarded straight to DataSourceModeToggle's own `onChange` -- see
    // that property's doc comment. Defaults to a no-op so render tests
    // (and any other caller with no refresh loop to trigger) don't need to
    // supply one.
    var onDataSourceModeChange: () -> Void = {}

    // bluegull-aqi-e70.43: decides which mode's config section to show
    // below the toggle -- see this type's own doc comment on why this is a
    // second, independent binding rather than one threaded down from
    // DataSourceModeToggle.
    @AppStorage(DataSourceModeStore.userDefaultsKey, store: DataSourceModeStore.sharedDefaults)
    private var mode: DataSourceMode = DataSourceModeStore.defaultMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                // Fixed white (bluegull-aqi-as9) -- Settings now uses a
                // flat `AppBrand.settingsBackground`, not the gradient, so
                // every foreground element is just white, no top-vs-
                // bottom judgment call. See `settingsBackground`'s own
                // doc comment for why.
                Text("Settings")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .gesture(TapGesture().modifiers(.option).onEnded { isDevOverrideRevealed.toggle() })
                Spacer()
                Button("Done") { dismissWindow(id: "settings") }
                    .accessibilityIdentifier("settingsDoneButton")
            }

            DataSourceModeToggle(onChange: onDataSourceModeChange)

            // bluegull-aqi-e70.43: only the selected source's own section,
            // tab-style -- see this type's own doc comment.
            switch mode {
            case .direct:
                AirNowAPIKeyEntryView()
                DirectTimeoutStepper()
            case .service:
                // Fixed white, not adaptive `.secondary` -- this whole
                // panel is a flat `AppBrand.settingsBackground` now
                // (bluegull-aqi-as9), so every foreground element is
                // just white, no per-element gradient-position judgment
                // call.
                Text("Service uses BlueGull's shared backend -- no API key needed.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                ServiceTimeoutStepper()
            }

            brandDivider
            PinnedLocationsView()
            brandDivider
            // bluegull-aqi-as9: a tighter inner VStack (8, not the outer
            // VStack's own 20) -- Steve: "less space between them." These
            // read as one related group of app-behavior options (plus
            // CompletelyRemoveButton, moved up here from below the
            // version label per Steve's own request -- "with the
            // options," not off on its own at the very bottom anymore),
            // so a tighter, denser spacing between them reads better than
            // the same wide gaps used between unrelated sections
            // elsewhere in this panel.
            VStack(alignment: .leading, spacing: 8) {
                LaunchAtLoginToggle()
                MenuBarColorStyleToggle()
                MenuBarAQILabelToggle()
                CompletelyRemoveButton()
            }

            if isDevOverrideRevealed {
                brandDivider
                DevServiceURLOverrideView()
            }

            brandDivider
            // bluegull-aqi-fw4.9: which exact build this is -- three
            // ad-hoc DMGs went out to a tester all labeled "1.0" before
            // this existed, indistinguishable from each other.
            Text(AppVersionInfo.current)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityIdentifier("appVersionLabel")
        }
        .padding()
        // bluegull-aqi-e70.45: narrowed from 420/460 now that
        // DataSourceModeToggle's segmented labels are short ("Service"/
        // "Direct", bluegull-aqi-a22) instead of full sentences -- that
        // was this window's actual widest content, per this property's own
        // prior doc comment; shortening it is what makes a narrower range
        // safe rather than reintroducing the truncation the wider range was
        // originally written to avoid. 360/400, not 340/360 -- Steve asked
        // for the pinned-location fields 50% wider (bluegull-aqi-a22), so
        // this needs enough room for the widened Address field (270) plus
        // the Add button beside it.
        //
        // IMPORTANT, confirmed live 2026-08-25: none of this actually
        // takes effect on a machine that already has a saved
        // "NSWindow Frame settings" entry (AppKit's own frame autosave,
        // keyed by this Window's `id` -- same mechanism WidgetDetailView's
        // own doc comment describes for "widget-detail") -- a persisted
        // frame from before this change (Steve's own dev machine had one
        // at 1106pt wide) wins over whatever `idealWidth` SwiftUI computes
        // here, silently. There's no code-level fix for an *existing*
        // stale saved frame short of clearing it (`defaults delete
        // solutions.bluegull.aqi "NSWindow Frame settings"` once, or
        // resizing the window back down by hand) -- this only guarantees
        // correct sizing for a window with no saved frame yet (a fresh
        // install, or after that one-time clear).
        .frame(minWidth: 360, idealWidth: 400)
        // bluegull-aqi-as9: a FLAT background, not `AppBrand.backgroundGradient()`
        // -- reverted from the gradient bluegull-aqi-a22 originally gave
        // this panel. Steve, 2026-08-27: "It's been way too fiddly to
        // deal with making the foreground... contrast with gradient
        // background... getting user complaints about the contrast."
        // See `AppBrand.settingsBackground`'s own doc comment for the
        // full reasoning -- scoped to Settings alone; the popover and
        // detail window keep the gradient.
        .background(AppBrand.settingsBackground)
        // bluegull-aqi-a22: one shared tint for every bordered control in
        // this panel (buttons, the segmented Picker, the switches below)
        // -- Steve wanted the fields' new blue background (`brandFieldStyle`)
        // and the buttons to visibly match, not just both-be-blue-ish in
        // two different shades.
        .tint(AppBrand.midBlue)
        .accessibilityIdentifier("settingsView")
        // bluegull-aqi-a22: forcibly repositions the real NSWindow after it
        // appears -- three things were tried and confirmed live, on Steve's
        // three-display rig (2026-08-25: built-in 2560x1664 plus two
        // external 1920x1200s), before landing on this one:
        // `.defaultPosition(.center)` (BluegullAQIApp) did nothing --
        // AppKit's initial placement for a window opened from a
        // MenuBarExtra popover's gear button seems to anchor near that
        // trigger point regardless of the scene-level hint.
        // `NSWindow.center()` centers on "the screen with the most area"
        // (Apple's own doc wording) -- still landed off-screen (System
        // Events reported {1744, -1040}, size {400, 655}).
        // Centering on `NSEvent.mouseLocation`'s own screen fared no
        // better (System Events then reported {760, 253}, nominally
        // within that screen's own bounds, still not visible to Steve --
        // never fully explained; some Spaces/display-arrangement
        // interaction on this rig, not a coordinate math bug as far as
        // could be determined).
        // What DID work, confirmed live: manually setting the window's
        // position to a small, safe offset from the origin -- Steve
        // confirmed {100, 100} was fully visible. This mirrors that
        // exactly (not computed centering) -- a small top-left inset from
        // `NSScreen.main`'s own `visibleFrame` origin, using the real
        // screen bounds rather than a hardcoded global (100, 100) so this
        // still behaves sanely on a single-display machine.
        //
        // bluegull-aqi-8iz, revised from the unconditional version above:
        // only intervenes when `isStaleFrame` says the CURRENT frame is
        // actually broken (see that function's own doc comment) -- a
        // real, live concern Steve raised, not just this dev machine's
        // own 3-display quirk: anyone who installed a pre-a22 version and
        // upgraded by just dragging the new .app over the old one (how
        // virtually everyone upgrades -- nobody runs an uninstaller
        // first) still carries THAT version's stale saved frame (up to
        // 1106pt wide, per this exact bug's own earlier investigation)
        // into the redesigned, much-narrower Settings panel. Gating on
        // `isStaleFrame`, rather than always repositioning on every open
        // the way the first version of this fix did, also means a user's
        // own deliberate resize/move of this window (once it's a sane
        // size to begin with) is respected afterward instead of snapping
        // back to the same spot every time they open Settings.
        // `DispatchQueue.main.async`, not `.onAppear` directly, so this
        // runs after AppKit's own initial placement pass, not before it.
        .onAppear {
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: { $0.title == "Settings" }),
                      SettingsWindowFrameSanitizer.isStale(window.frame) else { return }
                // Reset WIDTH only, not height -- `isStale` no longer
                // checks height at all (see its own doc comment on why a
                // fixed height cap kept misfiring on this panel's own
                // legitimate growth); a stale frame's real problem is
                // always its width or its position, and `.windowResizability
                // (.contentSize)` (BluegullAQIApp's Window scene) re-derives
                // the correct height from actual content on its own right
                // after this, so there's no need to guess one here.
                window.setContentSize(NSSize(width: 400, height: window.frame.height))
                guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
                let inset: CGFloat = 60
                window.setFrameOrigin(CGPoint(
                    x: visibleFrame.minX + inset,
                    y: visibleFrame.maxY - window.frame.height - inset
                ))
            }
        }
    }

    // Fixed white hairline, not the default `Divider()` -- that renders as
    // adaptive system gray, which doesn't read against AppBrand's
    // background (bluegull-aqi-a22), same fix as the popover/detail
    // window's own (bluegull-aqi-e70.52).
    private var brandDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.28))
            .frame(height: 1)
    }
}
