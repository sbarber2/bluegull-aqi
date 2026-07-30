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
}
