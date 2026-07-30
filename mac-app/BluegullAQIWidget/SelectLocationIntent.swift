import AppIntents
import BluegullAQIKit

/// A selectable location for widget configuration (bluegull-aqi-mtm.3):
/// either the synthetic "current location" option, or one of the user's
/// pinned locations (bluegull-aqi-e70.5). `location` is `nil` only for the
/// "current location" case -- the widget can't resolve GPS itself
/// (doc/DESIGN.md "Widget extension (WidgetKit)"), so that case falls back
/// to whatever the container app most recently cached
/// (`WidgetTimelineComputer.currentSnapshot(for:)`, `nil` argument).
struct LocationOptionEntity: AppEntity {
    static let currentLocationID = "current"

    let id: String
    let name: String
    let location: Location?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Location"
    static var defaultQuery = LocationOptionQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var currentLocation: LocationOptionEntity {
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
struct LocationOptionQuery: EntityQuery {
    func entities(for identifiers: [LocationOptionEntity.ID]) async throws -> [LocationOptionEntity] {
        allOptions().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LocationOptionEntity] {
        allOptions()
    }

    func defaultResult() async -> LocationOptionEntity? {
        .currentLocation
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

struct SelectLocationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Location"
    static var description = IntentDescription("Choose which location this widget shows air quality for.")

    // Optional, no default: @Parameter's `default:` for an AppEntity-typed
    // parameter must be a compile-time literal (confirmed via a real build
    // error -- ".currentLocation" isn't one, since it's a computed static
    // property), so "current location" is represented as nil here instead
    // and resolved in the provider, not baked into the parameter itself.
    @Parameter(title: "Location")
    var location: LocationOptionEntity?

    // Genuinely unconditional (bluegull-aqi-mtm.8): WidgetKit reads
    // `location` directly off the intent instance it hands to
    // `AppIntentTimelineProvider`, not from this method's result --
    // there's no branch on `location`'s value to unit test here. The real
    // pinned-location-selection logic is `WidgetLocationOptions.all(from:)`
    // above, which is what's actually tested.
    func perform() async throws -> some IntentResult {
        .result()
    }
}
