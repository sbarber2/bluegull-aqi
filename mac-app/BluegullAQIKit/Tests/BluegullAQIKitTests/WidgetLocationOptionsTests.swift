import XCTest
@testable import BluegullAQIKit

final class WidgetLocationOptionsTests: XCTestCase {
    private let home = PinnedLocation(label: "Home", location: Location(latitude: 37.7749, longitude: -122.4194))
    private let work = PinnedLocation(label: "Work", location: Location(latitude: 37.3861, longitude: -122.0839))

    func testCurrentLocationIsAlwaysPresentEvenWithNoPins() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        XCTAssertEqual(WidgetLocationOptions.all(from: store), [.currentLocation])
    }

    func testCurrentLocationComesFirstFollowedByEveryPin() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([home, work])

        XCTAssertEqual(WidgetLocationOptions.all(from: store), [.currentLocation, .pinned(home), .pinned(work)])
    }
}
