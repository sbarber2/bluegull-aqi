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

    func testPinnedLocationExtractsTheUnderlyingLocation() {
        XCTAssertNil(LocationOption.currentLocation.pinnedLocation)
        XCTAssertEqual(LocationOption.pinned(home).pinnedLocation, home.location)
    }

    func testDisplayName() {
        XCTAssertEqual(LocationOption.currentLocation.displayName, "Current Location")
        XCTAssertEqual(LocationOption.pinned(home).displayName, "Home")
    }

    // MARK: - displayName(for:from:) (bluegull-aqi-mtm.27)

    func testDisplayNameForNilLocationIsCurrentLocation() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        XCTAssertEqual(WidgetLocationOptions.displayName(for: nil, from: store), "Current Location")
    }

    func testDisplayNameForAMatchingPinnedLocation() {
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([home, work])

        XCTAssertEqual(WidgetLocationOptions.displayName(for: home.location, from: store), "Home")
        XCTAssertEqual(WidgetLocationOptions.displayName(for: work.location, from: store), "Work")
    }

    func testDisplayNameRoundsBeforeMatching() {
        // Simulates float-formatting drift from the deep link's
        // String(Double)/Double(String:) round trip, not an exact bit-for-
        // bit match -- the whole reason this rounds both sides.
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([home])
        let slightlyOff = Location(latitude: home.location.latitude + 0.00001, longitude: home.location.longitude)

        XCTAssertEqual(WidgetLocationOptions.displayName(for: slightlyOff, from: store), "Home")
    }

    func testDisplayNameFallsBackWhenNoPinMatches() {
        // The pin was renamed or deleted since this widget was configured.
        let store = PinnedLocationsStore(store: InMemorySharedCacheStore())
        store.save([work])

        XCTAssertEqual(WidgetLocationOptions.displayName(for: home.location, from: store), "Pinned Location")
    }

    func testPersistenceIDRoundTripsThroughASelectionLookup() {
        let options: [LocationOption] = [.currentLocation, .pinned(home), .pinned(work)]
        for option in options {
            XCTAssertEqual(
                MenuBarLocationSelectionStore.selection(id: option.persistenceID, availableOptions: options),
                option
            )
        }
    }
}

final class MenuBarLocationSelectionStoreTests: XCTestCase {
    private let home = PinnedLocation(label: "Home", location: Location(latitude: 37.7749, longitude: -122.4194))

    func testNilIDFallsBackToCurrentLocation() {
        XCTAssertEqual(
            MenuBarLocationSelectionStore.selection(id: nil, availableOptions: [.currentLocation, .pinned(home)]),
            .currentLocation
        )
    }

    func testUnknownIDFallsBackToCurrentLocation() {
        // Simulates a pinned location that was selected, then deleted --
        // its old persistenceID no longer matches anything.
        XCTAssertEqual(
            MenuBarLocationSelectionStore.selection(id: "some-deleted-uuid", availableOptions: [.currentLocation]),
            .currentLocation
        )
    }

    func testKnownPinnedIDResolvesToThatOption() {
        XCTAssertEqual(
            MenuBarLocationSelectionStore.selection(
                id: home.id.uuidString,
                availableOptions: [.currentLocation, .pinned(home)]
            ),
            .pinned(home)
        )
    }
}
