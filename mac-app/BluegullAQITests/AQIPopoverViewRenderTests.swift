import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test, not a full snapshot-testing harness (that's
/// separately tracked for the widget in bluegull-aqi-mtm.10/mtm.11). Just
/// confirms AQIPopoverView actually renders without crashing for both the
/// empty and populated states -- the one thing "it compiles" doesn't prove,
/// and the popover only builds its content lazily when clicked, which isn't
/// otherwise exercisable without UI automation (bluegull-aqi-e70.9, not yet
/// built).
final class AQIPopoverViewRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashingWhenEmpty() {
        let image = render(AQIPopoverView(reading: nil))
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithData() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: [
                PollutantReading(
                    dateObserved: "2026-07-30",
                    hourObserved: "12",
                    localTimeZone: "PST",
                    reportingAreaName: "San Francisco",
                    siteID: "060750005",
                    siteName: "San Francisco",
                    parameterName: "PM2.5",
                    nowcastAQI: 42,
                    aqiCategoryName: "Good",
                    reportingAgency: "Bay Area Air District",
                    lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All",
                    lookupBoundary: "50 Miles"
                ),
            ]
        )

        let image = render(AQIPopoverView(reading: reading))
        XCTAssertNotNil(image)
    }

    @MainActor
    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        return renderer.nsImage
    }
}
