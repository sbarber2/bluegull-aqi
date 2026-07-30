import XCTest
@testable import BluegullAQIKit

final class AQIReadingTests: XCTestCase {
    private func makePollutant(parameterName: String, nowcastAQI: Int?) -> PollutantReading {
        PollutantReading(
            dateObserved: "2026-07-29",
            hourObserved: "14:00",
            localTimeZone: "PDT",
            reportingAreaName: "San Francisco",
            siteID: "060750005",
            siteName: "San Francisco",
            parameterName: parameterName,
            nowcastAQI: nowcastAQI,
            aqiCategoryName: "Good",
            reportingAgency: "Bay Area Air District",
            lookupBehavior: "Closest Reading By Pollutant",
            consideredMonitors: "All",
            lookupBoundary: "50 Miles"
        )
    }

    func testHoldsLocationAndPollutants() {
        let location = Location(latitude: 37.7749, longitude: -122.4194)
        let pollutants = [
            makePollutant(parameterName: "PM2.5", nowcastAQI: 31),
            makePollutant(parameterName: "OZONE", nowcastAQI: 20),
        ]
        let reading = AQIReading(location: location, pollutants: pollutants)

        XCTAssertEqual(reading.location, location)
        XCTAssertEqual(reading.pollutants.count, 2)
        XCTAssertEqual(reading.pollutants, pollutants)
    }

    func testEquality() {
        let location = Location(latitude: 37.7749, longitude: -122.4194)
        let pollutants = [makePollutant(parameterName: "PM2.5", nowcastAQI: 31)]

        XCTAssertEqual(
            AQIReading(location: location, pollutants: pollutants),
            AQIReading(location: location, pollutants: pollutants)
        )
    }

    func testCodableRoundTrip() throws {
        let original = AQIReading(
            location: Location(latitude: 37.7749, longitude: -122.4194),
            pollutants: [makePollutant(parameterName: "PM2.5", nowcastAQI: 31)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AQIReading.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
