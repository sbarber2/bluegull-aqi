import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as sibling render-test suites in
/// this target) -- confirms `AgedReadingIndicator` renders without
/// crashing, both when the underlying observation time parses and when it
/// doesn't (missing/unparseable AirNow fields).
final class AgedReadingIndicatorRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashingWithAParseableObservationTime() {
        let headline = PollutantReading(
            dateObserved: "2026-07-30",
            hourObserved: "12",
            localTimeZone: "PST",
            reportingAreaName: "San Francisco",
            siteID: "060750005",
            siteName: "San Francisco",
            parameterName: "PM2.5",
            nowcastAQI: 78,
            aqiCategoryName: "Moderate",
            reportingAgency: "Bay Area Air District",
            lookupBehavior: "Closest Reading By Pollutant",
            consideredMonitors: "All",
            lookupBoundary: "50 Miles"
        )
        XCTAssertNotNil(ImageRenderer(content: AgedReadingIndicator(headline: headline)).nsImage)
    }

    @MainActor
    func testRendersWithoutCrashingWhenObservationTimeDoesNotParse() {
        let headline = PollutantReading(
            dateObserved: "not-a-date",
            hourObserved: "not-an-hour",
            localTimeZone: "PST",
            reportingAreaName: "San Francisco",
            siteID: "060750005",
            siteName: "San Francisco",
            parameterName: "PM2.5",
            nowcastAQI: 78,
            aqiCategoryName: "Moderate",
            reportingAgency: "Bay Area Air District",
            lookupBehavior: "Closest Reading By Pollutant",
            consideredMonitors: "All",
            lookupBoundary: "50 Miles"
        )
        XCTAssertNotNil(ImageRenderer(content: AgedReadingIndicator(headline: headline)).nsImage)
    }
}
