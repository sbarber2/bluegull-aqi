import Foundation

/// Every location a currently-placed widget instance is configured to show,
/// recorded by the widget extension itself each time its `TimelineProvider`
/// computes an entry (bluegull-aqi-o4b) -- the container app can't learn
/// this any other way: `WidgetCenter.getCurrentConfigurations()` reliably
/// returns `nil` `configuration` for this app's `AppIntentConfiguration`-
/// based widgets (confirmed against real placed widgets, not just
/// documented behavior), so `AQIRefreshController` can't read each
/// instance's pin directly through that API. The widget's own
/// `TimelineProvider`, by contrast, gets handed the correct
/// `SelectLocationIntent` straight from WidgetKit -- this store is just
/// that value relayed through the one channel both processes share, the
/// App Group.
///
/// Two independent things get recorded: pinned locations (keyed by rounded
/// coordinates, one entry per distinct pin -- multiple widgets on the same
/// pin only need one fetch) and whether *any* widget currently wants
/// "Current Location" (a single last-seen timestamp, not a location -- the
/// container app already resolves live GPS itself). Both use a last-seen
/// timestamp rather than an explicit remove, since there's no reliable
/// per-instance identifier here to notice a widget being deleted -- a
/// removed widget's entry just stops being renewed and ages out.
public struct WidgetRequestedLocationsStore: Sendable {
    private static let pinnedKey = "widget-requested-locations"
    private static let currentLocationKey = "widget-requested-current-location-last-seen"

    /// Long enough that a still-placed widget's own reload cadence
    /// (`RefreshScheduler`, ~1 hour) renews an entry well before it expires;
    /// short enough that removing a widget doesn't leave its old location
    /// being polled indefinitely.
    public static let retention: TimeInterval = 6 * 3600

    private let store: SharedCacheStore?

    public init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        self.store = store
    }

    /// Called by the widget extension's `TimelineProvider` every time it
    /// computes an entry -- `location` is `configuration.location?.location`
    /// (`nil` for both "Current Location" and a not-yet-configured
    /// instance, same collapse `WidgetTimelineComputer.currentSnapshot(for:)`
    /// already does). A no-op if the App Group suite couldn't be opened.
    public func recordSeen(_ location: Location?, now: Date = Date()) {
        guard let store else { return }
        if let location {
            var entries = readPinned()
            entries[location.rounded] = now
            writePinned(entries, into: store)
        } else {
            store.set(try? JSONEncoder().encode(now), forKey: Self.currentLocationKey)
        }
    }

    /// Every distinct pinned location seen recently enough to still count as
    /// "some placed widget wants this" -- prunes anything older than
    /// `retention` while it's here, same reactive-sweep pattern as
    /// `AppGroupCache`.
    public func activePinnedLocations(now: Date = Date()) -> [Location] {
        guard let store else { return [] }
        var entries = readPinned()
        let cutoff = now.addingTimeInterval(-Self.retention)
        let staleKeys = entries.filter { $0.value < cutoff }.map(\.key)
        if !staleKeys.isEmpty {
            for key in staleKeys { entries.removeValue(forKey: key) }
            writePinned(entries, into: store)
        }
        return Array(entries.keys)
    }

    /// Whether any placed widget is currently configured to show "Current
    /// Location", recently enough to still count (see `retention`).
    public func isCurrentLocationRequested(now: Date = Date()) -> Bool {
        guard let store, let data = store.data(forKey: Self.currentLocationKey),
              let lastSeen = try? JSONDecoder().decode(Date.self, from: data) else { return false }
        return lastSeen >= now.addingTimeInterval(-Self.retention)
    }

    private func readPinned() -> [Location: Date] {
        guard let store, let data = store.data(forKey: Self.pinnedKey),
              let decoded = try? JSONDecoder().decode([Location: Date].self, from: data) else { return [:] }
        return decoded
    }

    private func writePinned(_ entries: [Location: Date], into store: SharedCacheStore) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: Self.pinnedKey)
    }
}
