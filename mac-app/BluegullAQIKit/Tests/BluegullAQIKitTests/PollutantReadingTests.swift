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

    func testAQI650DecodesAndCategorizesAsBeyondScale() throws {
        // bluegull-aqi-10h.16: a real, valid (if rare) reading must render,
        // not blank out the app.
        let json = fixtureJSON.replacingOccurrences(of: "\"nowcastAQI\": 31,", with: "\"nowcastAQI\": 650,")
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(json.utf8))

        XCTAssertEqual(reading.nowcastAQI, 650)
        XCTAssertEqual(reading.category, .beyondAQI)
        XCTAssertEqual(reading.category?.beyondScaleNotice, "Values above 500 are beyond the AQI scale")
    }

    func testNegativeNowcastAQIYieldsNilCategoryNotBeyondScale() throws {
        // bluegull-aqi-10h.16: malformed data (a parse/transport fault)
        // must not be conflated with a real "beyond the scale" reading.
        let json = fixtureJSON.replacingOccurrences(of: "\"nowcastAQI\": 31,", with: "\"nowcastAQI\": -5,")
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(json.utf8))

        XCTAssertEqual(reading.nowcastAQI, -5)
        XCTAssertNil(reading.category)
    }

    func testAttributionTextCreditsTheReportingAgencyFirst() throws {
        // bluegull-aqi-10h.15: AirNow Data Exchange Guidelines require
        // credit FIRST to the specific state/local/tribal agency.
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(fixtureJSON.utf8))
        XCTAssertEqual(reading.attributionText, "Data courtesy of Bay Area Air District")
    }

    func testAttributionTextIsNilWhenReportingAgencyMissing() throws {
        // bluegull-aqi-10h.15's defensive fallback case: if AirNow doesn't
        // supply an agency name, don't invent one -- the generic-credit
        // fallback is the app-level static EPA/AirNow branding shown alone.
        let json = fixtureJSON.replacingOccurrences(
            of: "\"reportingAgency\": \"Bay Area Air District\",", with: ""
        )
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(json.utf8))

        XCTAssertNil(reading.reportingAgency)
        XCTAssertNil(reading.attributionText)
    }

    func testAttributionTextIsNilWhenReportingAgencyBlank() throws {
        let json = fixtureJSON.replacingOccurrences(
            of: "\"reportingAgency\": \"Bay Area Air District\",", with: "\"reportingAgency\": \"\","
        )
        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(json.utf8))

        XCTAssertEqual(reading.reportingAgency, "")
        XCTAssertNil(reading.attributionText)
    }

    func testDecodesArrayOfMultiplePollutants() throws {
        let arrayJSON = "[\(fixtureJSON), \(fixtureJSON.replacingOccurrences(of: "PM2.5", with: "OZONE"))]"
        let readings = try JSONDecoder().decode([PollutantReading].self, from: Data(arrayJSON.utf8))

        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].parameterName, "PM2.5")
        XCTAssertEqual(readings[1].parameterName, "OZONE")
    }

    /// Regression for bluegull-aqi-10h.21. Verbatim shape of a real
    /// 2026-08-05 response for Boston Metro (42.36,-71.06), an aggregate
    /// reporting area: AirNow returns `null` for siteID/siteName/
    /// lookupBoundary when `lookupBehavior` is "Highest Reading From
    /// Assigned Sites" rather than naming one monitor. These were declared
    /// non-optional, which made the *entire* payload undecodable -- the
    /// location showed "Data Unavailable" permanently, in both data-source
    /// modes and both processes.
    func testDecodesAggregateReportingAreaWithNullSiteFields() throws {
        let bostonJSON = """
        {
            "dateObserved": "2026-08-05",
            "hourObserved": "7:00",
            "localTimeZone": "EDT",
            "reportingAreaName": "Boston Metro",
            "siteID": null,
            "siteName": null,
            "parameterName": "PM2.5",
            "nowcastAQI": 39,
            "aqiCategoryName": "Good",
            "reportingAgency": "Massachusetts Dept. of Environmental Protection",
            "lookupBehavior": "Highest Reading From Assigned Sites",
            "consideredMonitors": "All",
            "lookupBoundary": null
        }
        """

        let reading = try JSONDecoder().decode(PollutantReading.self, from: Data(bostonJSON.utf8))

        XCTAssertNil(reading.siteID)
        XCTAssertNil(reading.siteName)
        XCTAssertNil(reading.lookupBoundary)
        // The point of the fix: everything else still decodes and displays.
        XCTAssertEqual(reading.nowcastAQI, 39)
        XCTAssertEqual(reading.reportingAreaName, "Boston Metro")
        XCTAssertEqual(reading.category, .good)
        XCTAssertEqual(reading.attributionText, "Data courtesy of Massachusetts Dept. of Environmental Protection")
    }

    func testCodableRoundTrip() throws {
        let original = try JSONDecoder().decode(PollutantReading.self, from: Data(fixtureJSON.utf8))
        let reEncoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(PollutantReading.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }
}
