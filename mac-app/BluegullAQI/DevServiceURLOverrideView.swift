import SwiftUI
import BluegullAQIKit

/// Hidden dev/testing-only override for `BluegullServiceClient`'s backend
/// base URL (bluegull-aqi-e70.28). Not reachable through any visible
/// control -- `SettingsView` only shows this when its "Settings" title has
/// been Option-clicked, a secret gesture deliberately undiscoverable to an
/// ordinary user, so this never needs to look polished or guard against
/// casual misuse the way a shipped preference would.
///
/// Writes straight to the App Group suite (`DevServiceURLOverrideStore`),
/// same as `DataSourceModeToggle`'s reasoning -- the widget extension's own
/// fetches need to see the same override this sets, not a stale mirror.
struct DevServiceURLOverrideView: View {
    @State private var urlString = ""

    private let store: UserDefaults?

    init(store: UserDefaults? = DevServiceURLOverrideStore.sharedDefaults) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dev: Service Backend URL Override")
                .font(.headline)
            Text("Not a supported setting. Leave empty to use the real backend.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://…", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("devServiceURLOverrideField")
            HStack {
                Button("Save") { save() }
                    .accessibilityIdentifier("devServiceURLOverrideSaveButton")
                Button("Clear") { clear() }
                    .accessibilityIdentifier("devServiceURLOverrideClearButton")
            }
        }
        .onAppear { load() }
    }

    private func load() {
        urlString = store?.string(forKey: DevServiceURLOverrideStore.userDefaultsKey) ?? ""
    }

    private func save() {
        store?.set(urlString, forKey: DevServiceURLOverrideStore.userDefaultsKey)
    }

    private func clear() {
        store?.removeObject(forKey: DevServiceURLOverrideStore.userDefaultsKey)
        urlString = ""
    }
}
