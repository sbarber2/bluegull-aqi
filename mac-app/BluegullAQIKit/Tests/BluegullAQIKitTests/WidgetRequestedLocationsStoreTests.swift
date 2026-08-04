import XCTest
@testable import BluegullAQIKit

/// Bluegull-aqi-o4b: `WidgetCenter.getCurrentConfigurations()` reliably
/// returns `nil` `configuration` for this app's widgets, so
/// `AQIRefreshController` reads this store instead -- these tests exercise
/// the store's own logic (recording, rounding, retention) independent of
/// the widget extension that writes to it or the container app that reads
/// from it.
final class WidgetRequestedLocationsStoreTests: XCTestCase {
    private let pin = Location(latitude: 40.780729, longitude: -73.9920338)

    func testActivePinnedLocationsIsEmptyWhenNothingRecorded() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        XCTAssertEqual(store.activePinnedLocations(), [])
    }

    func testRecordSeenMakesALocationActive() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        store.recordSeen(pin)
        XCTAssertEqual(store.activePinnedLocations(), [pin.rounded])
    }

    func testRecordSeenRoundsBeforeStoring() {
        // Two widgets pinned close enough together to round to the same
        // ~1km cell should collapse to one fetch, not two.
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        let nearbyPin = Location(latitude: 40.780001, longitude: -73.991999)
        store.recordSeen(pin)
        store.recordSeen(nearbyPin)
        XCTAssertEqual(store.activePinnedLocations().count, 1)
    }

    func testRecordSeenWithNilLocationSetsCurrentLocationRequestedInstead() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        store.recordSeen(nil)
        XCTAssertTrue(store.isCurrentLocationRequested())
        XCTAssertEqual(store.activePinnedLocations(), [])
    }

    func testIsCurrentLocationRequestedIsFalseWhenNeverRecorded() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        XCTAssertFalse(store.isCurrentLocationRequested())
    }

    func testActivePinnedLocationsPrunesEntriesOlderThanRetention() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        let now = Date()
        store.recordSeen(pin, now: now)

        let stillFresh = now.addingTimeInterval(WidgetRequestedLocationsStore.retention - 1)
        XCTAssertEqual(store.activePinnedLocations(now: stillFresh), [pin.rounded])

        let expired = now.addingTimeInterval(WidgetRequestedLocationsStore.retention + 1)
        XCTAssertEqual(store.activePinnedLocations(now: expired), [])
    }

    func testIsCurrentLocationRequestedExpiresAfterRetention() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        let now = Date()
        store.recordSeen(nil, now: now)

        let expired = now.addingTimeInterval(WidgetRequestedLocationsStore.retention + 1)
        XCTAssertFalse(store.isCurrentLocationRequested(now: expired))
    }

    func testRecordSeenAgainRenewsAnEntryPastItsOriginalRetentionWindow() {
        // Mirrors a still-placed widget: its TimelineProvider re-records on
        // every reload, so its entry should never actually expire so long
        // as WidgetKit keeps calling it.
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        let now = Date()
        store.recordSeen(pin, now: now)

        let renewalTime = now.addingTimeInterval(WidgetRequestedLocationsStore.retention - 1)
        store.recordSeen(pin, now: renewalTime)

        let pastOriginalWindow = now.addingTimeInterval(WidgetRequestedLocationsStore.retention + 1)
        XCTAssertEqual(store.activePinnedLocations(now: pastOriginalWindow), [pin.rounded])
    }

    func testMultipleDistinctPinsAreAllActive() {
        let store = WidgetRequestedLocationsStore(store: InMemorySharedCacheStore())
        let otherPin = Location(latitude: 39.850879, longitude: -74.9068135)
        store.recordSeen(pin)
        store.recordSeen(otherPin)
        XCTAssertEqual(Set(store.activePinnedLocations()), Set([pin.rounded, otherPin.rounded]))
    }
}
