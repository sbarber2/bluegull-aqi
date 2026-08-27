import AppKit
import ServiceManagement
import SwiftUI
import BluegullAQIKit

/// "Completely Remove BlueGull AQI…" (bluegull-aqi-8iz) -- the primary,
/// discoverable uninstall path, distinct from the DMG-bundled
/// `mac-app/scripts/uninstall.command`. Steve's own reasoning for wanting
/// this in addition to the script: most people delete the install DMG
/// right after dragging the app to Applications, so a script that only
/// lives there is invisible to anyone who wants to clean up later --
/// unlike a script, this is reachable for as long as the app itself is.
///
/// Clears data via the proper `UserDefaults`/Keychain/`SMAppService` APIs
/// rather than raw filesystem removal on the app's own live sandbox
/// container -- deliberately NOT `rm -rf`ing
/// `~/Library/Containers/solutions.bluegull.aqi` from a still-running
/// process holding open file handles into it (the App Group's own
/// `instance.lock`, for one, per `BluegullAQIApp.init()`'s own doc
/// comment). `removePersistentDomain` goes through cfprefsd correctly and
/// avoids any file-level race with it entirely. This also means it
/// clears AppKit's own window-frame autosave entries ("NSWindow Frame
/// settings", "NSWindow Frame widget-detail") -- Steve specifically
/// asked this be checked, since a stuck stale saved frame from a version
/// installed before the Settings redesign (bluegull-aqi-a22) is exactly
/// the kind of leftover state a real user could be carrying right now.
/// Ordinary UserDefaults keys live in the very domain this clears, so
/// yes, confirmed.
///
/// Does NOT delete the .app bundle itself -- self-deleting a running
/// process's own executable is technically possible on macOS but fragile
/// (permissions on `/Applications` aren't guaranteed writable by the
/// current user on every setup) and unusual even among apps that do
/// offer in-app uninstalls. Reveals the app in Finder instead so the
/// last step (drag to Trash) is one click away, then quits -- broader
/// filesystem-level cleanup (the app bundle, crash logs, LaunchServices
/// deregistration, Saved Application State) is what the bundled DMG
/// script is for, run after the app has fully quit, which is a strictly
/// safer time to do it.
struct CompletelyRemoveButton: View {
    @State private var showConfirmation = false

    var body: some View {
        Button(role: .destructive) {
            showConfirmation = true
        } label: {
            Text("Completely Remove BlueGull AQI\u{2026}")
        }
        .accessibilityIdentifier("completelyRemoveButton")
        .confirmationDialog(
            "Completely remove BlueGull AQI?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) { performRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all saved settings, pinned locations, cached AQI data, and your AirNow API key from this Mac. This cannot be undone.")
        }
    }

    private func performRemoval() {
        // Login item -- best-effort; a user who never enabled this just
        // gets a harmless no-op error, ignored deliberately.
        try? SMAppService.mainApp.unregister()

        // AirNow API key (Direct mode).
        try? AirNowAPIKeyStore().delete()

        // Every UserDefaults.standard key for this app -- including the
        // window-frame autosave entries; see this type's own doc comment.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // The App Group suite -- cached readings, pinned locations,
        // request timeouts, data-source mode, the dev backend override.
        UserDefaults(suiteName: UserDefaultsCacheStore.appGroupIdentifier)?
            .removePersistentDomain(forName: UserDefaultsCacheStore.appGroupIdentifier)

        // Reveal the now-data-less app in Finder so dragging it to the
        // Trash -- the one step this can't safely do itself -- is right
        // there, then quit. `NSApp.activate` first for the same reason
        // AQIPopoverView's own gear button does: an LSUIElement app isn't
        // reliably brought forward by a new window/Finder reveal alone.
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }
}
