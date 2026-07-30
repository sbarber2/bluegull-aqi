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

    // MARK: - Per-instance location configuration (bluegull-aqi-mtm.3)

    func testCurrentSnapshotForASpecificLocationReturnsThatLocationsEntry() {
        let store = InMemorySharedCacheStore()
        let otherLocation = Location(latitude: 40.7128, longitude: -74.0060)
        let otherReading = AQIReading(location: otherLocation, pollutants: reading.pollutants)
        let cache = AppGroupCache(store: store)
        cache.put(reading, for: location)
        cache.put(otherReading, for: otherLocation)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot(for: otherLocation).reading, otherReading)
    }

    func testCurrentSnapshotForASpecificLocationNeverFallsBackToADifferentLocationsData() {
        // The subtle case: a specific location was requested but has
        // nothing cached -- must be nil, NOT silently fall back to
        // mostRecentEntry() and show a different pin's data by surprise.
        let store = InMemorySharedCacheStore()
        let requestedButUncachedLocation = Location(latitude: 51.5074, longitude: -0.1278)
        AppGroupCache(store: store).put(reading, for: location)  // some OTHER location is cached

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertNil(computer.currentSnapshot(for: requestedButUncachedLocation).reading)
    }

    func testCurrentSnapshotWithNoLocationFallsBackToMostRecentEntry() {
        let store = InMemorySharedCacheStore()
        AppGroupCache(store: store).put(reading, for: location)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot(for: nil).reading, reading)
    }
}
