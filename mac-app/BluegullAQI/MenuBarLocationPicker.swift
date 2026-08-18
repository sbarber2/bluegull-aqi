import SwiftUI
import BluegullAQIKit

/// Lets the user choose which location the menu bar app/popover displays
/// (bluegull-aqi-e70.21) -- entirely independent of each widget
/// instance's own selection (`SelectLocationIntent`, bluegull-aqi-mtm.3).
/// Persisted via `MenuBarLocationSelectionStore` (`UserDefaults.standard`,
/// container-app-only).
///
/// Composed into `AQIPopoverView`. Loads its own options on appear, same
/// pattern `PinnedLocationsView` already uses for its own list -- no
/// shared state threaded through from `BluegullAQIApp`, since both this
/// picker and Settings' pinned-locations editor read the same
/// `PinnedLocationsStore` independently and don't need to stay live-
/// synced with each other within a single popover appearance.
struct MenuBarLocationPicker: View {
    @AppStorage(MenuBarLocationSelectionStore.userDefaultsKey)
    private var selectedID: String = MenuBarLocationSelectionStore.defaultSelectionID

    @State private var options: [LocationOption] = [.currentLocation]

    /// Called after the selection changes, so the caller can trigger an
    /// immediate refetch for the newly selected location rather than
    /// waiting for the next scheduled refresh.
    let onChange: () -> Void

    // bluegull-aqi-e70.27: reports the *resolved* selection (fallback-aware
    // via `MenuBarLocationSelectionStore.selection(id:availableOptions:)`,
    // same helper `AQIRefreshController` already uses) -- not just the raw
    // stored ID. A stored ID that no longer matches any current pin (e.g.
    // the pin it pointed at was since deleted) resolves to `.currentLocation`
    // here too, matching what actually gets fetched; a caller comparing the
    // raw AppStorage string against the literal "current" sentinel instead
    // would wrongly treat that stale-ID state as "some pin," not current
    // location -- exactly the bug this replaced (confirmed live: Steve had
    // zero pinned locations left, but `menuBarLocationSelection` still held
    // a stale pin UUID from before its pin was deleted).
    var onResolvedSelectionChange: (LocationOption) -> Void = { _ in }

    var body: some View {
        Picker("Location", selection: $selectedID) {
            ForEach(options, id: \.persistenceID) { option in
                Text(option.displayName).tag(option.persistenceID)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .onAppear {
            options = WidgetLocationOptions.all(from: PinnedLocationsStore())
            reportResolvedSelection()
        }
        .onChange(of: selectedID) {
            onChange()
            reportResolvedSelection()
        }
        .accessibilityIdentifier("menuBarLocationPicker")
    }

    private func reportResolvedSelection() {
        onResolvedSelectionChange(MenuBarLocationSelectionStore.selection(id: selectedID, availableOptions: options))
    }
}
