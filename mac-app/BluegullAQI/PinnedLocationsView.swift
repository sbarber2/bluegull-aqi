import SwiftUI
import BluegullAQIKit

/// Add/remove/rename pinned zip codes or addresses (bluegull-aqi-e70.5),
/// geocoded via `LocationResolver` and persisted through
/// `PinnedLocationsStore` -- the App Group, not `UserDefaults.standard`,
/// since the widget's future per-instance location configuration
/// (bluegull-aqi-mtm.3) needs to read this same list.
///
/// Composed into `SettingsView` (bluegull-aqi-e70.9), reachable via
/// `AQIPopoverView`'s gear icon.
struct PinnedLocationsView: View {
    @State private var locations: [PinnedLocation] = []
    @State private var newLabel = ""
    @State private var newAddress = ""
    @State private var errorMessage: String?
    @State private var isResolving = false

    private let store: PinnedLocationsStore
    private let resolver: LocationResolver

    init(store: PinnedLocationsStore = PinnedLocationsStore(), resolver: LocationResolver = LocationResolver()) {
        self.store = store
        self.resolver = resolver
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned Locations")
                .font(.headline)

            // Real confusion Steve hit directly: these looked like they
            // should affect the menu bar/popover somehow, but they don't
            // -- only each desktop widget's own per-instance "Edit
            // Widget" configuration reads this list (bluegull-aqi-mtm.3).
            // The menu bar's own location picker (bluegull-aqi-e70.21)
            // reads the exact same list, but its selection is completely
            // independent of any widget's.
            Text("Each desktop widget can be set to show one of these locations (or Current Location) individually — right-click the widget and choose Edit Widget. The menu bar's own location, set from its location picker, is separate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(locations) { pinned in
                HStack {
                    TextField("Name", text: labelBinding(for: pinned))
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                    Button(role: .destructive) {
                        remove(pinned)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                TextField("Name (e.g. Home)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("newPinnedLocationLabelField")
                TextField("Address or zip code", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("newPinnedLocationAddressField")
                Button("Add") {
                    Task { await add() }
                }
                .disabled(newLabel.isEmpty || newAddress.isEmpty || isResolving)
                .accessibilityIdentifier("addPinnedLocationButton")
            }
        }
        .onAppear { locations = store.load() }
    }

    private func labelBinding(for pinned: PinnedLocation) -> Binding<String> {
        Binding(
            get: { pinned.label },
            set: { rename(pinned, to: $0) }
        )
    }

    private func add() async {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        do {
            let resolvedLocation = try await resolver.resolve(address: newAddress)
            locations.append(PinnedLocation(label: newLabel, location: resolvedLocation))
            store.save(locations)
            newLabel = ""
            newAddress = ""
        } catch {
            errorMessage = "Couldn't find that address."
        }
    }

    private func remove(_ pinned: PinnedLocation) {
        locations.removeAll { $0.id == pinned.id }
        store.save(locations)
    }

    private func rename(_ pinned: PinnedLocation, to newLabel: String) {
        guard let index = locations.firstIndex(where: { $0.id == pinned.id }) else { return }
        locations[index].label = newLabel
        store.save(locations)
    }
}
