import XCTest
@testable import BluegullAQIKit

/// Fixture JSON mirrors the real AirNow `current/ziplatlong` response shape
/// (verified live against the API -- see doc/DESIGN.md and
/// service/tests/test_airnow_client.py's matching Python-side fixture).
final class PollutantReadingTests: XCTestCase {
    private let fixtureJSON = """
    {
        "dateObserved": "2026-07-29",
        "hourObserved": "14:00",
        "localTimeZone": "PDT",
        "reportingAreaName": "San Francisco",
        "siteID": "060750005",
        "siteName": "San Francisco",
        "parameterName": "PM2.5",
        "nowcastAQI": 31,
        "aqiCategoryName": "Good",
        "reportingAgency": "Bay Area Air District",
        "lookupBehavior": "Closest Reading By Pollutant",
        "consideredMonitors": "All",
        "lookupBoundary": "50 Miles"
    }
    """

    func testDecodesAllFieldsFromRealAirNowShape() throws {
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(fixtureJSON.utf8))

        XCTAssertEqual(reading.dateObserved, "2026-07-29")
        XCTAssertEqual(reading.hourObserved, "14:00")
        XCTAssertEqual(reading.localTimeZone, "PDT")
        XCTAssertEqual(reading.reportingAreaName, "San Francisco")
        XCTAssertEqual(reading.siteID, "060750005")
        XCTAssertEqual(reading.siteName, "San Francisco")
        XCTAssertEqual(reading.parameterName, "PM2.5")
        XCTAssertEqual(reading.nowcastAQI, 31)
        XCTAssertEqual(reading.aqiCategoryName, "Good")
        XCTAssertEqual(reading.reportingAgency, "Bay Area Air District")
        XCTAssertEqual(reading.lookupBehavior, "Closest Reading By Pollutant")
        XCTAssertEqual(reading.consideredMonitors, "All")
        XCTAssertEqual(reading.lookupBoundary, "50 Miles")
    }

    func testCategoryComputedFromNowcastAQI() throws {
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(fixtureJSON.utf8))
        XCTAssertEqual(reading.category, .good)
    }

    func testMissingNowcastAQIYieldsNilCategoryNotAnError() throws {
        // bluegull-aqi-10h.17: a response with a concentration but no AQI
        // must decode successfully, not fail or silently invent a category.
        let json = fixtureJSON.replacingOccurrences(of: "\"nowcastAQI\": 31,", with: "\"nowcastAQI\": null,")
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(json.utf8))

        XCTAssertNil(reading.nowcastAQI)
        XCTAssertNil(reading.category)
    }

    func testDecodesArrayOfMultiplePollutants() throws {
        let arrayJSON = "[\(fixtureJSON), \(fixtureJSON.replacingOccurrences(of: "PM2.5", with: "OZONE"))]"
        let readings = try JSONDecoder().decode([PollutantReading].self, from: Data(arrayJSON.utf8))

        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].parameterName, "PM2.5")
        XCTAssertEqual(readings[1].parameterName, "OZONE")
    }

    func testCodableRoundTrip() throws {
        let original = try JSONDecoder().decode(PollutantReading.self, from: Data(fixtureJSON.utf8))
        let reEncoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(PollutantReading.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }
}
