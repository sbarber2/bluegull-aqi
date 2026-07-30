import SwiftUI
import BluegullAQIKit

/// Entry/edit/clear for the user's own AirNow API key (Direct mode,
/// bluegull-aqi-e70.4), backed by `AirNowAPIKeyStore`
/// (bluegull-aqi-10h.5). Loads whatever's already saved on appear -- this
/// is the user's own key they typed in themselves, not a shared secret, so
/// showing it back to them for editing is reasonable (unlike, say, echoing
/// a password back).
///
/// Not yet wired into a settings window/sheet -- none exists yet, same as
/// `DataSourceModeToggle` (bluegull-aqi-e70.3). Composing this,
/// `e70.3`, and `e70.5` into one settings screen is separate,
/// not-yet-tracked integration work.
struct AirNowAPIKeyEntryView: View {
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var errorMessage: String?

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
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Save") { save() }
                    .disabled(apiKey.isEmpty)
                Button("Clear") { clear() }
                    .disabled(!hasSavedKey && apiKey.isEmpty)
            }
        }
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
