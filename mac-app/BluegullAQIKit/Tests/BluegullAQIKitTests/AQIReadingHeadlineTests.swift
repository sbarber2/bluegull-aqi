import XCTest
@testable import BluegullAQIKit

final class AQIReadingHeadlineTests: XCTestCase {
    func testHeadlinePollutantIsTheHighestAQI() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: [
                pollutant(parameterName: "OZONE", nowcastAQI: 42),
                pollutant(parameterName: "PM2.5", nowcastAQI: 78),
                pollutant(parameterName: "PM10", nowcastAQI: 15),
            ]
        )

        XCTAssertEqual(reading.headlinePollutant?.parameterName, "PM2.5")
        XCTAssertEqual(reading.headlinePollutant?.nowcastAQI, 78)
    }

    func testHeadlinePollutantIgnoresNilAQIEntries() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: [
                pollutant(parameterName: "OZONE", nowcastAQI: nil),
                pollutant(parameterName: "PM2.5", nowcastAQI: 30),
            ]
        )

        XCTAssertEqual(reading.headlinePollutant?.parameterName, "PM2.5")
    }

    func testHeadlinePollutantIsNilWhenEveryEntryLacksAQI() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: [
                pollutant(parameterName: "OZONE", nowcastAQI: nil),
                pollutant(parameterName: "PM2.5", nowcastAQI: nil),
            ]
        )

        XCTAssertNil(reading.headlinePollutant)
    }

    func testHeadlinePollutantIsNilForEmptyReading() {
        let reading = AQIReading(location: Location(latitude: 37.77, longitude: -122.42), pollutants: [])
        XCTAssertNil(reading.headlinePollutant)
    }

    private func pollutant(parameterName: String, nowcastAQI: Int?) -> PollutantReading {
        PollutantReading(
            dateObserved: "2026-07-30",
            hourObserved: "12",
            localTimeZone: "PST",
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
}
