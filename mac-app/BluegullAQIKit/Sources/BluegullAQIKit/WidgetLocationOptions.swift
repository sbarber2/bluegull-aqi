/// One widget-configuration location choice (bluegull-aqi-mtm.3): either
/// the synthetic "current location" option, or one of the user's pinned
/// locations (bluegull-aqi-e70.5).
public enum LocationOption: Sendable, Equatable {
    case currentLocation
    case pinned(PinnedLocation)
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
