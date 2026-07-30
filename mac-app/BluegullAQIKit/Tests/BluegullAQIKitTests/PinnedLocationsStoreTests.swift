import XCTest
@testable import BluegullAQIKit

final class PinnedLocationsStoreTests: XCTestCase {
    private let home = PinnedLocation(label: "Home", location: Location(latitude: 37.7749, longitude: -122.4194))
    private let work = PinnedLocation(label: "Work", location: Location(latitude: 37.3861, longitude: -122.0839))

    func testLoadReturnsEmptyArrayWhenNothingSaved() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        XCTAssertEqual(store.load(), [])
    }

    func testSaveThenLoadRoundTrips() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([home, work])
        XCTAssertEqual(store.load(), [home, work])
    }

    func testSaveReplacesThePreviousList() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([home])
        store.save([work])
        XCTAssertEqual(store.load(), [work])
    }

    func testDegradesToAnEmptyReadOnlyListWhenAppGroupSuiteCannotBeOpened() {
        let store = PinnedLocationsStore(store: nil)
        XCTAssertEqual(store.load(), [])
        store.save([home])  // must not crash
        XCTAssertEqual(store.load(), [])
    }
}
