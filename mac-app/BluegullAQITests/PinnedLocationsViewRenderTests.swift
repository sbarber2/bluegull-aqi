import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as the other `*RenderTests` in
/// this target). `PinnedLocationsStore`'s own load/save round-trip is
/// already tested at the package level (`PinnedLocationsStoreTests`); this
/// just confirms the view renders without crashing, for both the empty
/// and populated states.
///
/// Uses a real, dedicated `UserDefaultsCacheStore` suite (same pattern as
/// `BluegullAQIWidgetTimelineProviderTests`) rather than the package's
/// private in-memory fake, which isn't visible across the module boundary.
final class PinnedLocationsViewRenderTests: XCTestCase {
    private let testSuiteName = "solutions.bluegull.aqi.tests.PinnedLocationsViewRenderTests"

    private struct NeverCalledGeocoder: AddressGeocoder {
        func geocode(_ query: String) async throws -> Location {
            XCTFail("geocode(_:) should not be called just rendering the view")
            throw LocationResolverError.noResults
        }
    }

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    @MainActor
    func testRendersWithoutCrashingWhenEmpty() {
        let store = PinnedLocationsStore(store: UserDefaultsCacheStore(suiteName: testSuiteName))
        let resolver = LocationResolver(geocoder: NeverCalledGeocoder())
        let renderer = ImageRenderer(content: PinnedLocationsView(store: store, resolver: resolver))
        XCTAssertNotNil(renderer.nsImage)
    }

    @MainActor
    func testRendersWithoutCrashingWithExistingPins() {
        let store = PinnedLocationsStore(store: UserDefaultsCacheStore(suiteName: testSuiteName))
        store.save([
            PinnedLocation(label: "Home", location: Location(latitude: 37.7749, longitude: -122.4194)),
            PinnedLocation(label: "Work", location: Location(latitude: 37.3861, longitude: -122.0839)),
        ])

        let resolver = LocationResolver(geocoder: NeverCalledGeocoder())
        let renderer = ImageRenderer(content: PinnedLocationsView(store: store, resolver: resolver))
        XCTAssertNotNil(renderer.nsImage)
    }
}
