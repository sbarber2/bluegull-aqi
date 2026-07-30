import Foundation

/// A user-named location (bluegull-aqi-e70.5) -- "Home," "Work," a zip
/// code typed in directly, etc. Lives in the App Group, not
/// `UserDefaults.standard`: unlike `DataSourceModeStore` (container-app
/// only), the widget's future per-instance location configuration
/// (bluegull-aqi-mtm.3, App Intents) needs to read this same list to offer
/// pinned locations as options.
public struct PinnedLocation: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var label: String
    public var location: Location

    public init(id: UUID = UUID(), label: String, location: Location) {
        self.id = id
        self.label = label
        self.location = location
    }
}

/// Persists the pinned-locations list in the App Group.
///
/// `store` is optional and defaults to `UserDefaultsCacheStore()` (itself
/// failable) -- same graceful-degradation pattern as
/// `BluegullAQIWidgetTimelineProvider`: if the App Group suite can't be
/// opened, this behaves as an empty, read-only list rather than crashing.
public struct PinnedLocationsStore: Sendable {
    private static let key = "pinned-locations"

    private let store: SharedCacheStore?

    public init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        self.store = store
    }

    public func load() -> [PinnedLocation] {
        guard let store, let data = store.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PinnedLocation].self, from: data)) ?? []
    }

    /// A no-op if the App Group suite couldn't be opened -- there's
    /// nowhere to persist to, and silently failing is preferable to
    /// crashing over a settings edit.
    public func save(_ locations: [PinnedLocation]) {
        guard let store, let data = try? JSONEncoder().encode(locations) else { return }
        store.set(data, forKey: Self.key)
    }
}
