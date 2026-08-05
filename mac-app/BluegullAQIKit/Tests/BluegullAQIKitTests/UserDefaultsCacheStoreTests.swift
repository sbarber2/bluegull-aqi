import XCTest
@testable import BluegullAQIKit

/// Tests against the REAL UserDefaults API, unlike the Keychain/CoreLocation
/// tests elsewhere in this package -- confirmed empirically that
/// UserDefaults(suiteName:) works without a real registered App Group
/// entitlement, so there's no reason to only test a fake here
/// (bluegull-aqi-10h.7). A distinct, test-only suite name is used and
/// cleared in setUp/tearDown so this never touches the real App Group
/// suite or leaves data behind across test runs.
final class UserDefaultsCacheStoreTests: XCTestCase {
    private let testSuiteName = "solutions.bluegull.aqi.tests.UserDefaultsCacheStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    func testInitSucceedsForAnySuiteName() throws {
        XCTAssertNotNil(UserDefaultsCacheStore(suiteName: testSuiteName))
    }

    func testDataForKeyReturnsNilWhenAbsent() throws {
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        XCTAssertNil(store.data(forKey: "nonexistent-key"))
    }

    func testSetThenGetRoundTrips() throws {
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        let payload = Data("hello".utf8)

        store.set(payload, forKey: "test-key")
        XCTAssertEqual(store.data(forKey: "test-key"), payload)
    }

    func testSettingNilRemovesTheKey() throws {
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        store.set(Data("hello".utf8), forKey: "test-key")
        store.set(nil, forKey: "test-key")

        XCTAssertNil(store.data(forKey: "test-key"))
    }

    func testAllKeysReflectsWhatWasSet() throws {
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        store.set(Data("a".utf8), forKey: "aqi-cache-key-a")
        store.set(Data("b".utf8), forKey: "aqi-cache-key-b")

        let keys = Set(store.allKeys())
        XCTAssertTrue(keys.isSuperset(of: ["aqi-cache-key-a", "aqi-cache-key-b"]))
    }

    func testRetentionBoundingWorksAgainstRealUserDefaults() throws {
        // bluegull-aqi-10h.12: the fake-backed tests in AppGroupCacheTests
        // prove the *logic*; this proves allKeys()-driven pruning also
        // works against the real UserDefaults store it'll actually run
        // against, not just the fake.
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        let cache = AppGroupCache(store: store)
        let now = Date()
        let reading = AQIReading(
            location: Location(latitude: 0, longitude: 0),
            pollutants: [
                PollutantReading(
                    dateObserved: "2026-07-29", hourObserved: "14:00", localTimeZone: "GMT",
                    reportingAreaName: "Test", siteID: "1", siteName: "Test",
                    parameterName: "PM2.5", nowcastAQI: 10, aqiCategoryName: "Good",
                    reportingAgency: "Test Agency", lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All", lookupBoundary: "50 Miles"
                ),
            ]
        )

        for index in 0...AppGroupCache.maxRetainedEntries {
            let location = Location(latitude: Double(index), longitude: Double(index))
            cache.put(reading, for: location, hardTTL: AppGroupCache.defaultHardTTL, now: now.addingTimeInterval(Double(index)))
        }

        let remainingKeys = store.allKeys().filter { $0.hasPrefix("aqi-cache-") }
        XCTAssertEqual(remainingKeys.count, AppGroupCache.maxRetainedEntries)
        XCTAssertNil(cache.get(for: Location(latitude: 0, longitude: 0), now: now))
    }

    func testAppGroupCacheEndToEndAgainstRealUserDefaults() throws {
        let store = try XCTUnwrap(UserDefaultsCacheStore(suiteName: testSuiteName))
        let cache = AppGroupCache(store: store)
        let location = Location(latitude: 51.5074, longitude: -0.1278)
        let reading = AQIReading(
            location: location,
            pollutants: [
                PollutantReading(
                    dateObserved: "2026-07-29", hourObserved: "14:00", localTimeZone: "GMT",
                    reportingAreaName: "London", siteID: "000000001", siteName: "London",
                    parameterName: "PM2.5", nowcastAQI: 20, aqiCategoryName: "Good",
                    reportingAgency: "Test Agency", lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All", lookupBoundary: "50 Miles"
                ),
            ]
        )

        XCTAssertNil(cache.get(for: location))
        cache.put(reading, for: location)
        XCTAssertEqual(cache.get(for: location), reading)
        cache.remove(for: location)
        XCTAssertNil(cache.get(for: location))
    }
}
