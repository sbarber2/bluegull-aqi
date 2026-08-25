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
            // Fixed white, not adaptive `.primary`/`.secondary`
            // (bluegull-aqi-a22) -- this view's only call site
            // (SettingsView) shows it well below the top row, over
            // AppBrand's dark lower gradient.
            Text("Dev: Service Backend URL Override")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Not a supported setting. Leave empty to use the real backend.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            // bluegull-aqi-a22: `brandFieldStyle`, not `.roundedBorder` --
            // see that modifier's own doc comment.
            TextField("https://…", text: $urlString)
                .brandFieldStyle()
                .accessibilityIdentifier("devServiceURLOverrideField")
            // bluegull-aqi-a22: `.borderedProminent` -- same fix, same
            // reasoning as AirNowAPIKeyEntryView's own Save/Clear.
            HStack {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("devServiceURLOverrideSaveButton")
                Button("Clear") { clear() }
                    .buttonStyle(.borderedProminent)
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
