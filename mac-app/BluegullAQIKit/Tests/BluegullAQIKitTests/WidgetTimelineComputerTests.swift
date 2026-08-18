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
        AppGroupCache(store: store).put(reading, for: location, softTTL: 1, hardTTL: 1, now: now)

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

    // MARK: - lastSuccessfulFetchDate (bluegull-aqi-dc2.1)

    func testCurrentSnapshotSurfacesLastSuccessfulFetchDateEvenOnceTheEntryHasExpired() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()
        cache.put(reading, for: location, softTTL: 1, hardTTL: 1, now: now)
        cache.recordSuccessfulFetch(now: now)

        let computer = WidgetTimelineComputer(store: store)
        let snapshot = computer.currentSnapshot(now: now.addingTimeInterval(2))

        XCTAssertNil(snapshot.reading)
        XCTAssertEqual(snapshot.lastSuccessfulFetchDate, now)
    }

    func testCurrentSnapshotLastSuccessfulFetchDateIsNilWhenNeverFetched() {
        let computer = WidgetTimelineComputer(store: InMemorySharedCacheStore())
        XCTAssertNil(computer.currentSnapshot().lastSuccessfulFetchDate)
    }

    // MARK: - Per-instance location configuration (bluegull-aqi-mtm.3)

    func testCurrentSnapshotForASpecificLocationReturnsThatLocationsEntry() {
        let store = InMemorySharedCacheStore()
        let otherLocation = Location(latitude: 40.7128, longitude: -74.0060)
        let otherReading = AQIReading(location: otherLocation.rounded, pollutants: reading.pollutants)
        let cache = AppGroupCache(store: store)
        cache.put(reading, for: location)
        // `.rounded` -- AQIFetchCoordinator always caches under the fetch
        // client's own rounded location (bluegull-aqi-10h.11), never the
        // raw pin; writing under the raw `otherLocation` here would test a
        // write path production code never takes.
        cache.put(otherReading, for: otherLocation.rounded)

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

    func testCurrentSnapshotForAPinFindsTheEntryCachedUnderItsRoundedCoordinates() {
        // Regression for bluegull-aqi-nmn: AQIFetchCoordinator always caches
        // under the fetch client's own *rounded* location, never the raw
        // pin (bluegull-aqi-10h.11) -- every prior test in this file wrote
        // and read back the exact same unrounded Location value, which
        // can't catch a missing `.rounded()` on the read side. This mirrors
        // real usage: write rounded (as the coordinator does), read with
        // the widget's raw configured pin (as `BluegullAQIWidget` does).
        let store = InMemorySharedCacheStore()
        let rawPin = Location(latitude: 40.780729, longitude: -73.9920338)
        let roundedReading = AQIReading(location: rawPin.rounded, pollutants: reading.pollutants)
        AppGroupCache(store: store).put(roundedReading, for: rawPin.rounded)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot(for: rawPin).reading, roundedReading)
    }

    // MARK: - Freshness (bluegull-aqi-dc2.5)

    func testCurrentSnapshotFreshnessIsNilWhenNoReading() {
        let computer = WidgetTimelineComputer(store: InMemorySharedCacheStore())
        XCTAssertNil(computer.currentSnapshot().freshness)
    }

    func testCurrentSnapshotFreshnessIsFreshForARecentEntry() {
        let store = InMemorySharedCacheStore()
        AppGroupCache(store: store).put(reading, for: location)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot().freshness, .fresh)
    }

    /// The point of dc2.5, at the level a widget actually observes it: a
    /// soft-expired entry still renders (non-nil reading) AND is flagged
    /// stale, rather than the widget being unable to tell the two apart.
    func testCurrentSnapshotStillReturnsAReadingWhilePastSoftExpiryAndFlagsItStale() {
        let store = InMemorySharedCacheStore()
        let now = Date()
        // `.rounded` -- same write-side contract as everywhere else in this
        // file (see testCurrentSnapshotForAPinFindsTheEntryCachedUnderItsRoundedCoordinates).
        AppGroupCache(store: store).put(reading, for: location.rounded, softTTL: 10, hardTTL: 100, now: now)

        let computer = WidgetTimelineComputer(store: store)
        let snapshot = computer.currentSnapshot(for: location, now: now.addingTimeInterval(50))

        XCTAssertEqual(snapshot.reading, reading)
        XCTAssertEqual(snapshot.freshness, .stale)
    }

    func testCurrentSnapshotWithNoLocationFallsBackToMostRecentEntry() {
        let store = InMemorySharedCacheStore()
        AppGroupCache(store: store).put(reading, for: location)

        let computer = WidgetTimelineComputer(store: store)
        XCTAssertEqual(computer.currentSnapshot(for: nil).reading, reading)
    }

    // MARK: - Failed-fetch downgrade (bluegull-aqi-e70.39)

    /// The actual bug Steve hit: a Current Location widget never fetches
    /// for itself, so a reading still within its own TTL had no way to
    /// reflect that the active data source had just started failing.
    func testCurrentSnapshotDowngradesAFreshReadingWhenTheMostRecentFetchAttemptFailed() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()
        cache.put(reading, for: location.rounded, now: now)
        cache.recordSuccessfulFetch(now: now)
        cache.recordFailedFetch(now: now.addingTimeInterval(1))

        let computer = WidgetTimelineComputer(store: store)
        let snapshot = computer.currentSnapshot(for: location, now: now.addingTimeInterval(2))

        // Reading still shown -- same "don't discard good data" reasoning
        // as dc2.1 -- just no longer reported as unconditionally fresh.
        XCTAssertEqual(snapshot.reading, reading)
        XCTAssertEqual(snapshot.freshness, .stale)
    }

    func testCurrentSnapshotStaysFreshWhenTheMostRecentAttemptSucceededAfterAnEarlierFailure() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()
        cache.recordFailedFetch(now: now)
        cache.put(reading, for: location.rounded, now: now.addingTimeInterval(1))
        cache.recordSuccessfulFetch(now: now.addingTimeInterval(1))

        let computer = WidgetTimelineComputer(store: store)
        let snapshot = computer.currentSnapshot(for: location, now: now.addingTimeInterval(2))

        XCTAssertEqual(snapshot.freshness, .fresh)
    }
}
