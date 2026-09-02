import XCTest
@testable import BluegullAQIWidgetViews
import BluegullAQIKit

final class BluegullAQIWidgetEntryTests: XCTestCase {
    // bluegull-aqi-e70.27: `withResolvedPlaceName` is what
    // `BluegullAQIWidgetTimelineProvider` (untestable itself -- app-extension
    // targets can't be linked by a separate test target, same reasoning as
    // `WidgetTimelineComputer`'s own doc comment) uses to attach a
    // reverse-geocoded place name after the fact, alongside `locationName`
    // (not replacing it -- Steve wanted both visible).
    func testWithResolvedPlaceNameAttachesWithoutTouchingLocationName() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: []
        )
        let original = BluegullAQIWidgetEntry(
            date: Date(timeIntervalSince1970: 1000),
            reading: reading,
            configuredLocation: nil,
            locationName: "Current Location",
            lastSuccessfulFetchDate: Date(timeIntervalSince1970: 900),
            freshness: .fresh
        )
        XCTAssertNil(original.resolvedPlaceName)

        let updated = original.withResolvedPlaceName("San Francisco, CA")

        XCTAssertEqual(updated.resolvedPlaceName, "San Francisco, CA")
        XCTAssertEqual(updated.locationName, "Current Location")
        XCTAssertEqual(updated.date, original.date)
        XCTAssertEqual(updated.reading, original.reading)
        XCTAssertEqual(updated.configuredLocation, original.configuredLocation)
        XCTAssertEqual(updated.lastSuccessfulFetchDate, original.lastSuccessfulFetchDate)
        XCTAssertEqual(updated.freshness, original.freshness)
    }
}

/// bluegull-aqi-hib.7. The snapshot knowing background refresh is off is
/// worth nothing if the entry the widget actually renders drops it -- and
/// because `backgroundRefresh` defaults to `.working`, dropping it would
/// fail SILENTLY, showing a reassuring widget over a broken feature. Lives
/// in this target rather than alongside the derivation tests because
/// `BluegullAQIWidgetEntry` is in BluegullAQIWidgetViews, which
/// BluegullAQIKitTests cannot see.
final class WidgetEntryBackgroundRefreshTests: XCTestCase {
    /// A local duplicate rather than a shared import -- test-only files
    /// can't be linked across test targets (the same limitation
    /// `FakeLocationResolver` and `FakeKeychainStore` already document).
    private final class MemoryStore: SharedCacheStore, @unchecked Sendable {
        private var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data?, forKey key: String) { values[key] = data }
        func allKeys() -> [String] { Array(values.keys) }
    }

    private func entry(availability: LocationHelperAvailability) -> BluegullAQIWidgetEntry {
        let store = MemoryStore()
        LocationHelperStatusStore(store: store).recordAvailability(availability)
        return BluegullAQIWidgetEntry(WidgetTimelineComputer(store: store).currentSnapshot(for: nil))
    }

    func testTheStatusSurvivesFromSnapshotIntoTheEntry() {
        XCTAssertEqual(entry(availability: .requiresApproval).backgroundRefresh, .needsApproval)
    }

    /// The reverse-geocode step rebuilds the entry field by field, which is
    /// exactly the kind of copy that quietly loses a newly-added property.
    func testResolvingAPlaceNameDoesNotDropIt() {
        let resolved = entry(availability: .requiresApproval).withResolvedPlaceName("Oakland, CA")

        XCTAssertEqual(resolved.backgroundRefresh, .needsApproval)
        XCTAssertEqual(resolved.resolvedPlaceName, "Oakland, CA")
    }
}
