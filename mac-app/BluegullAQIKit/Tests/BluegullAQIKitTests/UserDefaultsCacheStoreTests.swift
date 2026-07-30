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
    private let testSuiteName = "org.bluegull.aqi.tests.UserDefaultsCacheStoreTests"

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
