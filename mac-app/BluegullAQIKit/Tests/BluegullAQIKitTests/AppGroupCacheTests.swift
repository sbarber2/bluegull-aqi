import XCTest
@testable import BluegullAQIKit

/// TTL/logic tests against InMemorySharedCacheStore, with a controllable
/// `now` for deterministic expiry testing -- see
/// UserDefaultsCacheStoreTests.swift for tests against the real store.
final class AppGroupCacheTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)
    private let reading = AQIReading(
        location: Location(latitude: 37.7749, longitude: -122.4194),
        pollutants: [
            PollutantReading(
                dateObserved: "2026-07-29", hourObserved: "14:00", localTimeZone: "PDT",
                reportingAreaName: "San Francisco", siteID: "060750005", siteName: "San Francisco",
                parameterName: "PM2.5", nowcastAQI: 31, aqiCategoryName: "Good",
                reportingAgency: "Bay Area Air District", lookupBehavior: "Closest Reading By Pollutant",
                consideredMonitors: "All", lookupBoundary: "50 Miles"
            ),
        ]
    )

    func testGetReturnsNilWhenNothingCached() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        XCTAssertNil(cache.get(for: location))
    }

    func testPutThenGetRoundTrips() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        cache.put(reading, for: location)
        XCTAssertEqual(cache.get(for: location), reading)
    }

    func testEntryServedWithinTTL() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let now = Date()
        cache.put(reading, for: location, ttl: AppGroupCache.defaultTTL, now: now)

        let justBeforeExpiry = now.addingTimeInterval(AppGroupCache.defaultTTL - 1)
        XCTAssertEqual(cache.get(for: location, now: justBeforeExpiry), reading)
    }

    func testEntryExpiresAfterTTL() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let now = Date()
        cache.put(reading, for: location, ttl: AppGroupCache.defaultTTL, now: now)

        let afterExpiry = now.addingTimeInterval(AppGroupCache.defaultTTL + 1)
        XCTAssertNil(cache.get(for: location, now: afterExpiry))
    }

    func testRemoveClearsTheEntry() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        cache.put(reading, for: location)
        cache.remove(for: location)
        XCTAssertNil(cache.get(for: location))
    }

    func testDifferentLocationsAreIndependent() {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let otherLocation = Location(latitude: 40.7128, longitude: -74.0060)

        cache.put(reading, for: location)
        XCTAssertNil(cache.get(for: otherLocation))
    }

    func testUndecodableDataIsTreatedAsAMissNotACrash() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        store.set(Data("not valid json".utf8), forKey: "aqi-cache-37.7749--122.4194")

        XCTAssertNil(cache.get(for: location))
    }
}
