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

    // MARK: - Retention bounding (bluegull-aqi-10h.12)

    func testExpiredEntryIsActuallyDeletedNotJustSkippedOnGet() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()
        cache.put(reading, for: location, ttl: 1, now: now)

        XCTAssertNil(cache.get(for: location, now: now.addingTimeInterval(2)))
        XCTAssertTrue(store.allKeys().isEmpty, "expired entry should have been deleted, not just skipped")
    }

    func testExpiredEntriesAreSweptOnEveryPutNotJustTheOneBeingWritten() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()
        let staleLocation = Location(latitude: 51.5074, longitude: -0.1278)

        cache.put(reading, for: staleLocation, ttl: 1, now: now)
        XCTAssertEqual(store.allKeys().count, 1)

        // Writing an entry for a DIFFERENT location, well after the first
        // one expired, should still sweep the first one away.
        let later = now.addingTimeInterval(10)
        cache.put(reading, for: location, ttl: AppGroupCache.defaultTTL, now: later)

        XCTAssertEqual(store.allKeys().count, 1)
        XCTAssertNil(cache.get(for: staleLocation, now: later))
        XCTAssertNotNil(cache.get(for: location, now: later))
    }

    func testEntryCountIsBoundedEvictingOldestFirst() {
        let store = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: store)
        let now = Date()

        // One more location than the cap allows, each written at a
        // distinct, increasing timestamp so eviction order is unambiguous.
        let locations = (0...AppGroupCache.maxRetainedEntries).map {
            Location(latitude: Double($0), longitude: Double($0))
        }
        for (index, loc) in locations.enumerated() {
            cache.put(reading, for: loc, ttl: AppGroupCache.defaultTTL, now: now.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(store.allKeys().count, AppGroupCache.maxRetainedEntries)
        // The very first (oldest) location written should have been evicted...
        XCTAssertNil(cache.get(for: locations[0], now: now))
        // ...but the most recently written one should still be present.
        XCTAssertNotNil(cache.get(for: locations.last!, now: now))
    }

    func testPruningNeverTouchesKeysOutsideItsOwnPrefix() {
        // A store shared for other purposes shouldn't have unrelated data
        // swept away by AppGroupCache's own housekeeping.
        let store = InMemorySharedCacheStore()
        store.set(Data("unrelated".utf8), forKey: "some-other-feature-key")
        let cache = AppGroupCache(store: store)

        cache.put(reading, for: location)

        XCTAssertEqual(store.data(forKey: "some-other-feature-key"), Data("unrelated".utf8))
    }
}
