import XCTest
@testable import BluegullAQIKit

/// Boundary and value tests against the AQI Technical Assistance Document
/// (EPA 454/B-18-007, Sept 2018) Tables 1-2, verbatim. Getting the colors
/// subtly wrong (e.g. Good as (0,255,0) instead of (0,228,0)) is the most
/// likely failure mode -- see bluegull-aqi-10h.2.
final class AQICategoryTests: XCTestCase {
    func testBoundaries() {
        XCTAssertEqual(AQICategory(aqi: 0), .good)
        XCTAssertEqual(AQICategory(aqi: 50), .good)
        XCTAssertEqual(AQICategory(aqi: 51), .moderate)
        XCTAssertEqual(AQICategory(aqi: 100), .moderate)
        XCTAssertEqual(AQICategory(aqi: 101), .unhealthyForSensitiveGroups)
        XCTAssertEqual(AQICategory(aqi: 150), .unhealthyForSensitiveGroups)
        XCTAssertEqual(AQICategory(aqi: 151), .unhealthy)
        XCTAssertEqual(AQICategory(aqi: 200), .unhealthy)
        XCTAssertEqual(AQICategory(aqi: 201), .veryUnhealthy)
        XCTAssertEqual(AQICategory(aqi: 300), .veryUnhealthy)
        XCTAssertEqual(AQICategory(aqi: 301), .hazardous)
        XCTAssertEqual(AQICategory(aqi: 500), .hazardous)
        XCTAssertEqual(AQICategory(aqi: 501), .beyondAQI)
        XCTAssertEqual(AQICategory(aqi: 999), .beyondAQI)
    }

    func testDescriptors() {
        XCTAssertEqual(AQICategory.good.descriptor, "Good")
        XCTAssertEqual(AQICategory.moderate.descriptor, "Moderate")
        XCTAssertEqual(AQICategory.unhealthyForSensitiveGroups.descriptor, "Unhealthy for Sensitive Groups")
        XCTAssertEqual(AQICategory.unhealthy.descriptor, "Unhealthy")
        XCTAssertEqual(AQICategory.veryUnhealthy.descriptor, "Very Unhealthy")
        XCTAssertEqual(AQICategory.hazardous.descriptor, "Hazardous")
        // Beyond-the-AQI-scale follows the Hazardous recommendations (TAD).
        XCTAssertEqual(AQICategory.beyondAQI.descriptor, "Hazardous")
    }

    func testColorsMatchTADExactly() {
        assertColor(.good, red: 0, green: 228, blue: 0, hex: "#00E400")
        assertColor(.moderate, red: 255, green: 255, blue: 0, hex: "#FFFF00")
        assertColor(.unhealthyForSensitiveGroups, red: 255, green: 126, blue: 0, hex: "#FF7E00")
        assertColor(.unhealthy, red: 255, green: 0, blue: 0, hex: "#FF0000")
        assertColor(.veryUnhealthy, red: 143, green: 63, blue: 151, hex: "#8F3F97")
        assertColor(.hazardous, red: 126, green: 0, blue: 35, hex: "#7E0023")
        // Beyond-the-AQI-scale uses the same color as Hazardous, not a
        // distinct/generic dark red.
        assertColor(.beyondAQI, red: 126, green: 0, blue: 35, hex: "#7E0023")
    }

    private func assertColor(
        _ category: AQICategory,
        red: Double,
        green: Double,
        blue: Double,
        hex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let color = category.color
        XCTAssertEqual(color.red, red, file: file, line: line)
        XCTAssertEqual(color.green, green, file: file, line: line)
        XCTAssertEqual(color.blue, blue, file: file, line: line)
        XCTAssertEqual(color.hex, hex, file: file, line: line)
    }

    func testCodableRoundTrip() throws {
        for category: AQICategory in [.good, .moderate, .unhealthyForSensitiveGroups, .unhealthy, .veryUnhealthy, .hazardous, .beyondAQI] {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(AQICategory.self, from: data)
            XCTAssertEqual(category, decoded)
        }
    }
}
