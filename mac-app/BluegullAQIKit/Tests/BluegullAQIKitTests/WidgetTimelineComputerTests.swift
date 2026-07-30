import XCTest
@testable import BluegullAQIKit

/// Fixture-driven tests for the widget's `TimelineProvider` logic
/// (bluegull-aqi-mtm.7) -- against `InMemorySharedCacheStore` here rather
/// than the widget extension target itself, since `app-extension` products
/// can't be linked against by a separate test target (see
/// `WidgetTimelineComputer`'s own doc comment for why this lives here).
final class WidgetTimelineComputerTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)
    private let reading = AQIReading(
        location: Location(latitude: 37.7749, longitude: -122.4194),
        pollutants: [
            PollutantReading(
                dateObserved: "2026-07-30", hourObserved: "12", localTimeZone: "PDT",
                reportingAreaName: "San Francisco", siteID: "060750005", siteName: "San Francisco",
                parameterName: "PM2.5", nowcastAQI: 42, aqiCategoryName: "Good",
                reportingAgency: "Bay Area Air District", lookupBehavior: "Closest Reading By Pollutant",
                consideredMonitors: "All", lookupBoundary: "50 Miles"
            ),
        ]
    )

    func testCurrentSnapshotHasNilReadingWhenCacheIsEmpty() {
        let computer = WidgetTimelineComputer(store: InMemorySharedCacheStore())
        XCTAssertNil(computer.currentSnapshot().reading)
    }

    func testCurrentSnapshotReturnsWhatTheContainerAppCached() {
        let store = InMemorySharedCacheStore()
        AppGroupCache(store: store).put(reading, for: location)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot().reading, reading)
    }

    func testCurrentSnapshotIsNilOnceTheCachedEntryHasExpired() {
        let store = InMemorySharedCacheStore()
        let now = Date()
        AppGroupCache(store: store).put(reading, for: location, ttl: 1, now: now)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertNil(computer.currentSnapshot(now: now.addingTimeInterval(2)).reading)
    }

    func testCurrentSnapshotDateMatchesWhatWasPassedIn() {
        let computer = WidgetTimelineComputer(store: InMemorySharedCacheStore())
        let now = Date()
        XCTAssertEqual(computer.currentSnapshot(now: now).date, now)
    }

    func testNextReloadDateIsStrictlyAfterNow() {
        let computer = WidgetTimelineComputer(store: InMemorySharedCacheStore())
        let now = Date()
        XCTAssertGreaterThan(computer.nextReloadDate(after: now), now)
    }
}
