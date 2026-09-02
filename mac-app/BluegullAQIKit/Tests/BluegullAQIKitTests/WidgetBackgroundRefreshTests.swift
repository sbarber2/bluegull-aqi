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

    /// bluegull-aqi-hib.8's open question, answered without waiting for a
    /// real upgrade: during the window between upgrading and the helper's
    /// first successful write, does a Current Location widget keep
    /// rendering the pre-upgrade entry, or blank?
    ///
    /// It keeps rendering, which is dc2.5's stale-while-revalidate design
    /// working as intended -- the entry the OLD app wrote is still inside
    /// its hard TTL and stays displayable, visibly aged, rather than
    /// snapping to "Data Unavailable" the moment the upgrade lands. The
    /// upgrade must not look like a data loss.
    func testAnUpgradeDoesNotBlankAnExistingCurrentLocationWidget() {
        let store = makeStore(availability: .notRegistered)
        // What the pre-helper app left behind, written an hour ago: past
        // the soft TTL, well inside the hard one.
        let now = Date()
        let cache = AppGroupCache(store: store)
        cache.putCurrentLocation(
            AQIReading(location: Location(latitude: 37.7749, longitude: -122.4194), pollutants: []),
            now: now.addingTimeInterval(-3700)
        )

        let snapshot = WidgetTimelineComputer(store: store).currentSnapshot(for: nil, now: now)

        XCTAssertNotNil(snapshot.reading, "the upgrade must not blank a widget that had data")
        XCTAssertEqual(snapshot.freshness, .stale, "and it must be labelled as aged, not passed off as current")
        XCTAssertEqual(snapshot.backgroundRefresh, .neverSetUp)
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
