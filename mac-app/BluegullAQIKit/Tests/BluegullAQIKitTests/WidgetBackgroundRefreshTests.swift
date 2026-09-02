import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.7's "both surfaces agree" criterion, at the seam where
/// they could most easily diverge: the widget runs in a different process
/// and cannot query `SMAppService` at all, so it depends entirely on what
/// the app wrote into the App Group.
final class WidgetBackgroundRefreshTests: XCTestCase {
    private let pinned = Location(latitude: 37.7749, longitude: -122.4194)

    private func makeStore(availability: LocationHelperAvailability) -> InMemorySharedCacheStore {
        let store = InMemorySharedCacheStore()
        LocationHelperStatusStore(store: store).recordAvailability(availability)
        return store
    }

    func testCurrentLocationWidgetLearnsBackgroundRefreshIsOff() {
        let computer = WidgetTimelineComputer(store: makeStore(availability: .notRegistered))

        let snapshot = computer.currentSnapshot(for: nil)

        XCTAssertEqual(snapshot.backgroundRefresh, .neverSetUp)
        XCTAssertNotNil(snapshot.backgroundRefresh.widgetCaption)
    }

    /// The criterion this protects: pinned locations need no location grant
    /// at all (confirmed live, bluegull-aqi-hib.12), so a pinned widget must
    /// never be told anything is wrong. Reporting a problem on a surface
    /// that is working is how a one-feature degradation reads as a broken
    /// app.
    func testPinnedWidgetIsNeverToldAnythingIsWrong() {
        let computer = WidgetTimelineComputer(store: makeStore(availability: .notRegistered))

        let snapshot = computer.currentSnapshot(for: pinned)

        XCTAssertEqual(snapshot.backgroundRefresh, .working)
        XCTAssertNil(snapshot.backgroundRefresh.widgetCaption)
    }
}
