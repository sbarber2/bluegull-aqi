import ServiceManagement
import SwiftUI

/// Settings toggle for launching BlueGull AQI automatically at login
/// (bluegull-aqi-fvt), via `SMAppService.mainApp` -- macOS's own modern
/// login-item API (13+; this project's own deployment target is 14, so no
/// availability guard is needed). Distinct from the separate, still-
/// undecided `bluegull-aqi-hib` epic's location-helper AGENT
/// (`SMAppService.agent`, a headless background process): that decision is
/// about keeping data fresh without the menu bar app running at all, and
/// remains unresolved (`hib.1`) -- this is just "launch the app that
/// already exists," independent of that outcome either way (see `hib.1`'s
/// own comment thread for why the two don't conflict).
///
/// Not backed by `@AppStorage` -- `SMAppService`'s own registration state
/// (in `System Settings > General > Login Items & Extensions`) IS the
/// state; a separate stored preference could drift from what's actually
/// registered (e.g. if the user manually removes it there), which is
/// exactly the kind of silent-desync failure mode `hib.3`'s own doc
/// comment already flagged for the agent case. `isEnabled` is `@State`,
/// refreshed from `SMAppService.mainApp.status` after every explicit
/// register/unregister call and again whenever this view reappears (e.g.
/// re-opening Settings after toggling something in System Settings) --
/// there's no push notification for an external change, so this is a
/// polling mitigation, not a guarantee of always being in sync.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Fixed white + `.toggleStyle(.switch)`, not adaptive
            // `.primary` + the platform-default checkbox (bluegull-aqi-a22)
            // -- same reasoning as `MenuBarColorStyleToggle`'s own comment.
            Toggle("Launch BlueGull AQI at login", isOn: binding)
                .toggleStyle(.switch)
                .foregroundStyle(.white)
                .accessibilityIdentifier("launchAtLoginToggle")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // `.requiresApproval`: registration succeeded, but macOS
            // itself defaults new login items to disabled pending explicit
            // user approval -- the toggle alone can't finish the job.
            if SMAppService.mainApp.status == .requiresApproval {
                Text("Approve this in System Settings \u{2192} General \u{2192} Login Items & Extensions.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .onAppear { refreshStatus() }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                errorMessage = nil
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    errorMessage = "Couldn't \(newValue ? "enable" : "disable") launch at login."
                }
                refreshStatus()
            }
        )
    }

    // `.enabled` and `.requiresApproval` both count as "on" for the
    // toggle's own position -- the user asked for it; `.requiresApproval`
    // just means macOS needs one more step before it actually takes
    // effect, which the caption above explains rather than the toggle
    // itself silently reverting to off.
    private func refreshStatus() {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            isEnabled = true
        case .notRegistered, .notFound:
            isEnabled = false
        @unknown default:
            isEnabled = false
        }
    }
}
