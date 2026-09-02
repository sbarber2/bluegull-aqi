import AppKit
import SwiftUI
import BluegullAQIKit

/// bluegull-aqi-hib.6's first-run explanation: the re-askable pre-prompt
/// standing in front of the one-shot system location prompt.
///
/// WHY A WINDOW AND NOT THE POPOVER. hib.6 drafted this as "the app opens
/// its popover automatically, once." That is not buildable and would not
/// work if it were. `MenuBarExtra` has exactly two initializers
/// (`content:label:` and `isInserted:content:label:`) and no API to present
/// its window programmatically -- checked against the SDK, not assumed. And
/// even given one, a `MenuBarExtra(.window)` popover is a lightweight
/// NSPanel that dismisses itself when it loses key status; the system
/// location prompt is precisely a focus change, so the explanation would
/// vanish underneath the dialog it triggered, taking the design's own
/// "determinate waiting-for-permission state" with it. This app already
/// opens two real `Window` scenes programmatically (Settings, and the
/// widget detail window) for a closely related reason -- see
/// `AQIPopoverView`'s note on why Settings is a window rather than a sheet
/// over the popover. A third is the consistent answer, not a workaround.
///
/// Plain language throughout, per the design: nothing here says "helper",
/// "agent", "XPC" or "launchd". The user is being asked whether BlueGull may
/// keep their air quality up to date, which is the only part that concerns
/// them.
struct LocationSetupView: View {
    @Bindable var coordinator: LocationSetupCoordinator

    /// True when the app already had location permission before this update
    /// -- so the copy can acknowledge the upgrade rather than reading as an
    /// arbitrary new demand for something the user already granted once
    /// (hib.6's upgrade branch; the migration itself is hib.8).
    var isUpgrade = false

    /// Closes the window. Injected rather than reaching for
    /// `\.dismissWindow` so render tests can construct this view without a
    /// scene around it.
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch coordinator.phase {
            case .explaining:
                explanation
            case .registering, .waitingForPermission:
                waiting
            case .granted:
                result(
                    icon: "checkmark.circle",
                    tint: .green,
                    title: "You're all set",
                    body: "BlueGull AQI will keep the air quality for where you are up to date, whether or not this app is open."
                )
            case .refused:
                refused
            case .unanswered:
                result(
                    icon: "clock",
                    tint: .orange,
                    title: "No answer yet",
                    body: "The permission request wasn't answered. You can try again whenever you like."
                )
            case .failed(let message):
                result(icon: "exclamationmark.triangle", tint: .orange, title: "Something went wrong", body: message)
            }

            if coordinator.needsSystemSettingsApproval {
                approvalNote
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 420)
        .background(AppBrand.settingsBackground)
        .accessibilityIdentifier("locationSetupView")
    }

    private var header: some View {
        Text(coordinator.phase == .explaining ? "Air quality where you are" : "Background updates")
            .font(.title2.bold())
            .foregroundStyle(.white)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Deliberately leads with what the user gets, not with what we
            // need. The permission is the second sentence because it is the
            // means, not the point.
            Text(isUpgrade
                 ? "BlueGull AQI now keeps this up to date in the background, so your widgets stay current even when the app isn't open."
                 : "BlueGull AQI shows the air quality for wherever you are. To keep that current -- including on your desktop widgets -- it needs to check your location in the background.")
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("macOS will ask you to allow this. You can say no now and turn it on later from the BlueGull menu.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(coordinator.phase == .registering ? "Setting up..." : "Waiting for your answer...")
                    .foregroundStyle(.white)
            }
            if coordinator.phase == .waitingForPermission {
                Text("macOS should be showing a permission request. If you don't see it, check behind other windows.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one branch we cannot undo. Says so plainly and points at the only
    /// remaining path, rather than offering a "try again" that CoreLocation
    /// would silently ignore.
    private var refused: some View {
        VStack(alignment: .leading, spacing: 10) {
            result(
                icon: "location.slash",
                tint: .orange,
                title: "Location is turned off for BlueGull",
                body: "BlueGull AQI can't ask again -- macOS only asks once. To turn it on, open System Settings \u{203A} Privacy & Security \u{203A} Location Services and enable BlueGull AQI."
            )
            Text("You can still use BlueGull AQI by adding specific locations in Settings. Those don't need location access at all.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func result(icon: String, tint: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Registration can succeed and still leave the agent switched off:
    /// macOS defaults new background items to disabled pending explicit
    /// approval, and nothing else would tell the user why nothing happens.
    private var approvalNote: some View {
        Text("One more step: turn on BlueGull AQI in System Settings \u{203A} General \u{203A} Login Items & Extensions.")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.86))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch coordinator.phase {
            case .explaining:
                Button("Not now") {
                    coordinator.declineForNow()
                    onDismiss()
                }
                .accessibilityIdentifier("locationSetupNotNowButton")
                Button("Turn On") {
                    Task { await coordinator.enable() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("locationSetupTurnOnButton")

            case .registering, .waitingForPermission:
                // No dismiss while a system prompt may be on screen: closing
                // this window would leave the user answering a dialog with
                // nothing left explaining what asked for it.
                EmptyView()

            case .refused:
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
                    )
                }
                .accessibilityIdentifier("locationSetupOpenSettingsButton")
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.defaultAction)

            case .granted, .unanswered, .failed:
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("locationSetupDoneButton")
            }
        }
    }
}

/// Thin scene wrapper that supplies `LocationSetupView`'s `onDismiss` from
/// the environment. Exists so the view itself takes a plain closure and can
/// be constructed by a render test with no scene around it -- the same
/// injectable-dependency shape `AQIPopoverView` uses for its
/// `locationResolver`.
struct LocationSetupWindowContent: View {
    let coordinator: LocationSetupCoordinator

    @Environment(\.dismissWindow) private var dismissWindow

    /// An upgrade rather than a fresh install (bluegull-aqi-hib.8).
    ///
    /// Reads the fact recorded at the first launch of a helper-aware build,
    /// replacing hib.6's stop-gap, which asked "has this install ever
    /// fetched?" live. That was right only on the very first launch: any
    /// FRESH install that had since added a pinned location also answers
    /// yes, and would have been told it upgraded from something it never
    /// had. Still deliberately not read from
    /// `CLLocationManager.authorizationStatus` -- constructing a location
    /// manager in the app is exactly what hib.6 removed.
    private var isUpgrade: Bool {
        guard let store = UserDefaultsCacheStore() else { return false }
        return LocationHelperStatusStore(store: store).upgradedFromPreHelperBuild()
    }

    var body: some View {
        LocationSetupView(
            coordinator: coordinator,
            isUpgrade: isUpgrade,
            onDismiss: { dismissWindow(id: "location-setup") }
        )
    }
}
