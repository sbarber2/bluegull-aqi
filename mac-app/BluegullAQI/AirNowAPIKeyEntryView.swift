import SwiftUI
import BluegullAQIKit

/// Entry/edit/clear for the user's own AirNow API key (Direct mode,
/// bluegull-aqi-e70.4), backed by `AirNowAPIKeyStore`
/// (bluegull-aqi-10h.5). Loads whatever's already saved on appear -- this
/// is the user's own key they typed in themselves, not a shared secret, so
/// showing it back to them for editing is reasonable (unlike, say, echoing
/// a password back).
///
/// Composed into `SettingsView` (bluegull-aqi-e70.9), reachable via
/// `AQIPopoverView`'s gear icon. As of bluegull-aqi-e70.43, `SettingsView`
/// only ever renders this at all while Direct mode is selected (tab-style,
/// see that type's own doc comment) -- this view no longer needs its own
/// `.disabled(mode != .direct)` check (bluegull-aqi-e70.30's original
/// mechanism), since it's hidden entirely rather than shown-but-inert.
struct AirNowAPIKeyEntryView: View {
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    private let store: AirNowAPIKeyStore

    init(store: AirNowAPIKeyStore = AirNowAPIKeyStore()) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AirNow API Key")
                .font(.headline)
            SecureField("Enter your AirNow API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .accessibilityIdentifier("airNowAPIKeyField")
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Save") { save() }
                    .disabled(apiKey.isEmpty)
                    .accessibilityIdentifier("saveAPIKeyButton")
                Button("Clear") { clear() }
                    .disabled(!hasSavedKey && apiKey.isEmpty)
                    .accessibilityIdentifier("clearAPIKeyButton")
            }
        }
        // bluegull-aqi-e70.30: without this, AppKit hands this field
        // first-responder status by default (it's the first focusable
        // control in the settings window) -- pin the default focus state
        // to unfocused instead of leaving it to that heuristic.
        .defaultFocus($isFieldFocused, false)
        .onAppear { load() }
    }

    private func load() {
        do {
            if let saved = try store.load() {
                apiKey = saved
                hasSavedKey = true
            }
        } catch {
            errorMessage = "Couldn't load your saved key."
        }
    }

    private func save() {
        do {
            try store.save(apiKey)
            hasSavedKey = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save your key. Try again."
        }
    }

    private func clear() {
        do {
            try store.delete()
            apiKey = ""
            hasSavedKey = false
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't clear your key. Try again."
        }
    }
}
