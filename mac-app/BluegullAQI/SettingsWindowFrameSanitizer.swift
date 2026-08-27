import AppKit

/// Shared "is this saved Settings-window frame trustworthy" check
/// (bluegull-aqi-8iz), used from two places for two different reasons:
///
/// 1. `BluegullAQIApp.init()` calls `scrubIfStale()` BEFORE any window is
///    created, so a stale value never gets restored/displayed at all --
///    confirmed live, Steve, 2026-08-27: `SettingsView`'s own `.onAppear`
///    correction (below) runs too late to avoid a visible flash ("Settings
///    frame came up large and quickly flashed to the narrower width"), since
///    by the time `.onAppear` fires, AppKit has already restored AND
///    rendered the stale frame for at least one frame. Removing the
///    UserDefaults key here means there's nothing left for AppKit to
///    restore from when the window is actually created later -- SwiftUI's
///    own `.defaultSize`/`.windowResizability(.contentSize)`
///    (`BluegullAQIApp`'s `Window` scene) computes the correct size from a
///    clean slate instead, with no flash.
/// 2. `SettingsView`'s own `.onAppear` keeps a runtime check as defense in
///    depth -- e.g. if this type's own string parsing ever misses a raw
///    value shaped differently than expected, or a future macOS version
///    changes the autosave format -- so a bad frame still gets caught (with
///    a flash, the previously-known-working fallback) rather than silently
///    persisting forever.
///
/// One shared `isStale(_:)` definition, not two copies, so the two call
/// sites can't drift into disagreeing about what counts as broken.
enum SettingsWindowFrameSanitizer {
    static let userDefaultsKey = "NSWindow Frame settings"

    /// Removes the saved frame from `UserDefaults.standard` if it looks
    /// stale. Safe to call unconditionally on every launch -- a no-op
    /// when there's no saved value yet, or when the saved value still
    /// looks reasonable.
    static func scrubIfStale() {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let frame = parseFrame(raw), isStale(frame) else { return }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // A saved/current window frame counts as "stale" -- worth silently
    // correcting rather than trusting -- if its WIDTH is unreasonable, or
    // if it doesn't intersect ANY currently connected screen at all (the
    // off-screen case, confirmed live on bluegull-aqi-a22's own 3-display
    // investigation). Either condition alone is enough.
    //
    // Deliberately NOT a height check -- confirmed live, Steve, 2026-08-27,
    // after an EARLIER version of this function DID include one (900pt
    // cap): that earlier cap started misfiring on a perfectly legitimate,
    // correctly-laid-out window once this panel's real content grew past
    // it (measured live: 1064.5pt tall with Direct mode, a saved API key,
    // and several pinned locations -- every individual section measured
    // completely normally in isolation; the total was just the honest sum
    // of `VStack`'s own 20pt spacing across the now-larger number of
    // sections). Height in a vertical `VStack` like this one is EXPECTED
    // to keep growing as features get added (this file's own history is
    // the proof: two more toggles landed after the last time anyone
    // measured this panel's "normal" height) -- policing it with a fixed
    // number means this same false-positive bug WILL recur the next time
    // Settings legitimately grows, not just an edge case worth tolerating
    // once. Width has no equivalent problem: nothing in this panel's
    // layout grows it horizontally, so it stays a reliable signal --
    // 600pt cleanly separates the old pre-a22 design's 1106pt-wide bug
    // from anything this panel's current (or plausible future) width
    // could legitimately be.
    static func isStale(_ frame: NSRect) -> Bool {
        let isUnreasonablyWide = frame.width > 600
        let isOffScreen = !NSScreen.screens.contains { $0.frame.intersects(frame) }
        return isUnreasonablyWide || isOffScreen
    }

    // AppKit's frame-autosave string format: space-separated
    // "x y width height [screenX screenY screenWidth screenHeight]" in
    // its own bottom-up-origin coordinate space -- only the first 4
    // numbers (the window's own frame) matter here.
    private static func parseFrame(_ raw: String) -> NSRect? {
        let components = raw.split(separator: " ").compactMap { Double($0) }
        guard components.count >= 4 else { return nil }
        return NSRect(x: components[0], y: components[1], width: components[2], height: components[3])
    }
}
