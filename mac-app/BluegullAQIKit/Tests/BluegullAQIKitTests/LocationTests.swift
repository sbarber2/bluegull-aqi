import XCTest
@testable import BluegullAQIKit

final class LocationTests: XCTestCase {
    func testEquality() {
        XCTAssertEqual(
            Location(latitude: 37.7749, longitude: -122.4194),
            Location(latitude: 37.7749, longitude: -122.4194)
        )
        XCTAssertNotEqual(
            Location(latitude: 37.7749, longitude: -122.4194),
            Location(latitude: 40.7128, longitude: -74.0060)
        )
    }

    func testCodableRoundTrip() throws {
        let original = Location(latitude: 37.7749, longitude: -122.4194)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Location.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testRoundedMatchesServerCacheKeyPrecision() {
        // bluegull-aqi-10h.11: must match cache.py's LOCATION_KEY_PRECISION
        // (2 decimal places) exactly, for cache-hit-rate alignment.
        let location = Location(latitude: 37.774929, longitude: -122.419416)
        let rounded = location.rounded

        XCTAssertEqual(rounded.latitude, 37.77, accuracy: 0.0001)
        XCTAssertEqual(rounded.longitude, -122.42, accuracy: 0.0001)
    }

    func testRoundedRoundsHalfUpNotJustTruncates() {
        // 37.775 should round to 37.78, not truncate to 37.77 -- confirms
        // this actually rounds rather than just chopping digits.
        let location = Location(latitude: 37.775, longitude: -122.0)
        XCTAssertEqual(location.rounded.latitude, 37.78, accuracy: 0.0001)
    }

    func testRoundedIsIdempotent() {
        let location = Location(latitude: 37.77, longitude: -122.42)
        XCTAssertEqual(location.rounded, location)
    }
}
