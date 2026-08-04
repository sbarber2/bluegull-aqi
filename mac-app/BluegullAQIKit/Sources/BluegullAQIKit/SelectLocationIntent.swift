import AppIntents

/// The widget extension's own `Widget.kind` string
/// (`BluegullAQIWidget.swift`) -- shared here so it's a single literal, not
/// duplicated across targets that can drift apart.
public enum BluegullWidgetKind {
    public static let aqi = "BluegullAQIWidget"
}

/// A selectable location for widget configuration (bluegull-aqi-mtm.3):
/// either the synthetic "current location" option, or one of the user's
/// pinned locations (bluegull-aqi-e70.5). `location` is `nil` only for the
/// "current location" case -- the widget can't resolve GPS itself
/// (doc/DESIGN.md "Widget extension (WidgetKit)"), so that case falls back
/// to whatever the container app most recently cached
/// (`WidgetTimelineComputer.currentSnapshot(for:)`, `nil` argument).
///
/// Lives in `BluegullAQIKit`, not the widget extension target, even though
/// `AppEntity`/`WidgetConfigurationIntent` conformance is otherwise the
/// kind of AppIntents-specific code this framework-agnostic package
/// avoids -- the container app needs this exact type too, to interpret
/// each placed widget's own configuration via `WidgetCenter`
/// (bluegull-aqi-igu: the container app is what proactively refreshes
/// every widget's configured location, since the widget extension itself
/// can't fetch). Same reasoning as `WidgetLocationOptions.all(from:)`
/// below: pulled into the shared package the moment a second target
/// needed it, not preemptively.
public struct LocationOptionEntity: AppEntity {
    public static let currentLocationID = "current"

    public let id: String
    public let name: String
    public let location: Location?

    public init(id: String, name: String, location: Location?) {
        self.id = id
        self.name = name
        self.location = location
    }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Location"
    public static var defaultQuery = LocationOptionQuery()

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public static var currentLocation: LocationOptionEntity {
        LocationOptionEntity(id: currentLocationID, name: "Current Location", location: nil)
    }
}

/// Options come from `PinnedLocationsStore` (bluegull-aqi-e70.5, App Group
/// backed) plus the synthetic "current location" entry -- never a live
/// CoreLocation/network fetch, same "widget doesn't fetch itself"
/// constraint as everywhere else in this extension. The actual
/// list-building is `WidgetLocationOptions.all(from:)`
/// (bluegull-aqi-mtm.8) -- this just converts each `LocationOption` into
/// the `AppEntity`-conforming type App Intents needs.
public struct LocationOptionQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [LocationOptionEntity.ID]) async throws -> [LocationOptionEntity] {
        allOptions().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [LocationOptionEntity] {
        allOptions()
    }

    // A newly-placed widget starts out as a one-time snapshot of whatever
    // the menu bar currently shows (bluegull-aqi-mtm.20), not the
    // synthetic "Current Location" option -- `SharedMenuBarLocationStore`
    // is how the container app mirrors that selection into the App Group,
    // since this runs in the widget extension process, which can't read
    // `MenuBarLocationSelectionStore`'s own `UserDefaults.standard`. Falls
    // back to `.currentLocation` if nothing's been mirrored yet (fresh
    // install, before the container app's first `refreshNow()`) or the
    // mirrored ID no longer matches anything (its pinned location was since
    // deleted) -- same fallback `MenuBarLocationSelectionStore.selection
    // (id:availableOptions:)` uses for the analogous case.
    public func defaultResult() async -> LocationOptionEntity? {
        let mirroredID = SharedMenuBarLocationStore().load()
        return allOptions().first { $0.id == mirroredID } ?? .currentLocation
    }

    private func allOptions() -> [LocationOptionEntity] {
        WidgetLocationOptions.all(from: PinnedLocationsStore()).map { option in
            switch option {
            case .currentLocation:
                return .currentLocation
            case .pinned(let pinned):
                return LocationOptionEntity(id: pinned.id.uuidString, name: pinned.label, location: pinned.location)
            }
        }
    }
}

public struct SelectLocationIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select Location"
    public static var description = IntentDescription("Choose which location this widget shows air quality for.")

    // Optional, no default: @Parameter's `default:` for an AppEntity-typed
    // parameter must be a compile-time literal (confirmed via a real build
    // error -- ".currentLocation" isn't one, since it's a computed static
    // property), so "current location" is represented as nil here instead
    // and resolved by callers, not baked into the parameter itself.
    @Parameter(title: "Location")
    public var location: LocationOptionEntity?

    public init() {}

    // Genuinely unconditional (bluegull-aqi-mtm.8): WidgetKit reads
    // `location` directly off the intent instance it hands to
    // `AppIntentTimelineProvider`, not from this method's result --
    // there's no branch on `location`'s value to unit test here. The real
    // pinned-location-selection logic is `WidgetLocationOptions.all(from:)`
    // above, which is what's actually tested.
    public func perform() async throws -> some IntentResult {
        .result()
    }
}
