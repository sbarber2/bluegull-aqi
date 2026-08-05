import XCTest
@testable import BluegullAQIKit

/// `AQICacheEntry.freshness(at:)`/`isExpired(at:)` in isolation
/// (bluegull-aqi-dc2.5) -- `AppGroupCacheTests` covers the store-level
/// behavior built on top of these.
final class AQICacheEntryTests: XCTestCase {
    private let reading = AQIReading(
        location: Location(latitude: 37.7749, longitude: -122.4194),
        pollutants: [
            PollutantReading(
                dateObserved: "2026-08-05", hourObserved: "12:00", localTimeZone: "PDT",
                reportingAreaName: "San Francisco", siteID: "060750005", siteName: "San Francisco",
                parameterName: "PM2.5", nowcastAQI: 31, aqiCategoryName: "Good",
                reportingAgency: "Bay Area Air District", lookupBehavior: "Closest Reading By Pollutant",
                consideredMonitors: "All", lookupBoundary: "50 Miles"
            ),
        ]
    )

    private func makeEntry(now: Date, softTTL: TimeInterval, hardTTL: TimeInterval) -> AQICacheEntry {
        AQICacheEntry(
            reading: reading,
            fetchedAt: now,
            softExpiresAt: now.addingTimeInterval(softTTL),
            hardExpiresAt: now.addingTimeInterval(hardTTL)
        )
    }

    func testFreshBeforeSoftExpiry() {
        let now = Date()
        let entry = makeEntry(now: now, softTTL: 10, hardTTL: 100)
        XCTAssertEqual(entry.freshness(at: now.addingTimeInterval(5)), .fresh)
        XCTAssertFalse(entry.isExpired(now: now.addingTimeInterval(5)))
    }

    func testStaleBetweenSoftAndHardExpiry() {
        let now = Date()
        let entry = makeEntry(now: now, softTTL: 10, hardTTL: 100)
        XCTAssertEqual(entry.freshness(at: now.addingTimeInterval(50)), .stale)
        // The whole point of the two-threshold model: still not "expired."
        XCTAssertFalse(entry.isExpired(now: now.addingTimeInterval(50)))
    }

    func testExpiredAfterHardExpiry() {
        let now = Date()
        let entry = makeEntry(now: now, softTTL: 10, hardTTL: 100)
        XCTAssertEqual(entry.freshness(at: now.addingTimeInterval(100)), .expired)
        XCTAssertTrue(entry.isExpired(now: now.addingTimeInterval(100)))
    }

    func testExactlyAtSoftExpiryIsAlreadyStale() {
        // `now < softExpiresAt` is the fresh condition -- boundary belongs
        // to stale, not fresh, same "equal counts as expired" convention
        // isExpired already used before this feature existed.
        let now = Date()
        let entry = makeEntry(now: now, softTTL: 10, hardTTL: 100)
        XCTAssertEqual(entry.freshness(at: now.addingTimeInterval(10)), .stale)
    }

    func testExactlyAtHardExpiryIsAlreadyExpired() {
        let now = Date()
        let entry = makeEntry(now: now, softTTL: 10, hardTTL: 100)
        XCTAssertEqual(entry.freshness(at: now.addingTimeInterval(100)), .expired)
    }
}
