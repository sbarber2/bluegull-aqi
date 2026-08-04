import Foundation

/// One widget-configuration location choice (bluegull-aqi-mtm.3): either
/// the synthetic "current location" option, or one of the user's pinned
/// locations (bluegull-aqi-e70.5).
public enum LocationOption: Sendable, Equatable {
    case currentLocation
    case pinned(PinnedLocation)

    /// The concrete `Location` for a pinned option, nil for
    /// `.currentLocation` -- that case needs live GPS resolution, which
    /// this framework-agnostic type deliberately has no CoreLocation
    /// dependency to do itself. Callers resolve it themselves when nil.
    public var pinnedLocation: Location? {
        if case .pinned(let pinned) = self { return pinned.location }
        return nil
    }

    /// User-facing label -- "Current Location" for the synthetic option,
    /// otherwise the pinned location's own name.
    public var displayName: String {
        switch self {
        case .currentLocation: return "Current Location"
        case .pinned(let pinned): return pinned.label
        }
    }

    /// Stable string identity for persistence (bluegull-aqi-e70.21's menu
    /// bar location picker): "current" for the synthetic option,
    /// otherwise the pinned location's UUID string. Mirrors the sentinel
    /// the widget's own `LocationOptionEntity` uses (bluegull-aqi-mtm.3),
    /// kept as an independent constant since app-extension targets can't
    /// be linked by the container app (see that type's own doc comment).
    public var persistenceID: String {
        switch self {
        case .currentLocation: return "current"
        case .pinned(let pinned): return pinned.id.uuidString
        }
    }
}

public enum WidgetLocationOptions {
    /// "Current Location" (always first) plus every pinned location --
    /// the full set of options a widget instance's `SelectLocationIntent`
    /// can offer.
    ///
    /// Pulled out of the widget extension's own App Intents `EntityQuery`
    /// specifically so it's unit-testable at all (bluegull-aqi-mtm.8): an
    /// `app-extension` target can't be linked against by a separate test
    /// target, same constraint `WidgetTimelineComputer` was extracted for
    /// (bluegull-aqi-mtm.7) -- `AppEntity`/`EntityQuery` conformance itself
    /// still has to live in the extension (needs the `AppIntents` import,
    /// which this framework-agnostic package deliberately doesn't take on),
    /// but the actual list-building logic doesn't need to.
    public static func all(from store: PinnedLocationsStore) -> [LocationOption] {
        [.currentLocation] + store.load().map(LocationOption.pinned)
    }
}

/// Which location the menu bar app/popover itself displays
/// (bluegull-aqi-e70.21) -- entirely independent of each widget
/// instance's own selection (`SelectLocationIntent`, bluegull-aqi-mtm.3):
/// the menu bar has exactly one selection, widgets each have their own.
/// `UserDefaults.standard`, not the App Group -- container-app-only
/// setting, same reasoning as `DataSourceModeStore`.
public enum MenuBarLocationSelectionStore {
    public static let userDefaultsKey = "menuBarLocationSelection"
    public static let defaultSelectionID = "current"

    /// Resolves a persisted `persistenceID` back to a real `LocationOption`
    /// against the current pinned-locations list. Falls back to
    /// `.currentLocation` if `id` is nil (never set) or doesn't match
    /// anything in `availableOptions` (e.g. the pinned location it
    /// referred to was since deleted) -- never a crash or a stuck
    /// selection pointing at nothing.
    public static func selection(id: String?, availableOptions: [LocationOption]) -> LocationOption {
        guard let id, let match = availableOptions.first(where: { $0.persistenceID == id }) else {
            return .currentLocation
        }
        return match
    }
}

/// Mirrors `MenuBarLocationSelectionStore`'s current selection into the App
/// Group (bluegull-aqi-mtm.20) -- `MenuBarLocationSelectionStore` itself is
/// deliberately `UserDefaults.standard` (container-app-only, see its own
/// doc comment above), which the widget extension process can't read at
/// all. Written by `AQIRefreshController` every `refreshNow()` (the same
/// place that already resolves the menu bar's current selection); read by
/// `LocationOptionQuery.defaultResult()` in the widget extension to seed a
/// newly-placed widget's starting configuration with a one-time snapshot of
/// whatever the menu bar currently shows. App Intents only calls
/// `defaultResult()` once, at placement time, so this is never a live
/// link -- an already-placed widget is unaffected by later menu bar
/// changes, same as any other explicitly-configured widget.
public struct SharedMenuBarLocationStore: Sendable {
    private static let key = "menu-bar-location-selection-mirror"

    private let store: SharedCacheStore?

    public init(store: SharedCacheStore? = UserDefaultsCacheStore()) {
        self.store = store
    }

    /// Persists `persistenceID` (`LocationOption.persistenceID`) -- a no-op
    /// if the App Group suite couldn't be opened.
    public func save(persistenceID: String) {
        guard let store, let data = try? JSONEncoder().encode(persistenceID) else { return }
        store.set(data, forKey: Self.key)
    }

    /// nil if never written, the App Group suite couldn't be opened, or the
    /// stored value is undecodable.
    public func load() -> String? {
        guard let store, let data = store.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
}
