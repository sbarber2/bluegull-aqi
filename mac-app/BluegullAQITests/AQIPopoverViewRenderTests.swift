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
        let image = render(AQIPopoverView(reading: nil, lastError: nil, lastFetchedAt: nil, onLocationChange: {}))
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithData() {
        let reading = sampleReading(reportingAgency: "Bay Area Air District")
        let image = render(AQIPopoverView(reading: reading, lastError: nil, lastFetchedAt: nil, onLocationChange: {}))
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithDataAndLastFetchedAt() {
        // Exercises `updatedCaption`'s `Text(_:style: .relative)` path,
        // not just the nil-lastFetchedAt case above.
        let reading = sampleReading(reportingAgency: "Bay Area Air District")
        let image = render(
            AQIPopoverView(reading: reading, lastError: nil, lastFetchedAt: Date(), onLocationChange: {})
        )
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWhenReportingAgencyIsMissing() {
        // The tier-1 agency credit is absent, but tier 2 (AttributionCopy.staticCredit)
        // must never be omitted (bluegull-aqi-10h.15) -- exercises that fallback path.
        let reading = sampleReading(reportingAgency: nil)
        let image = render(AQIPopoverView(reading: reading, lastError: nil, lastFetchedAt: nil, onLocationChange: {}))
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithAnErrorAlongsideAStillGoodReading() {
        // bluegull-aqi-dc2.1: revisits e70.24's original behavior -- a
        // failed refresh no longer hides an existing reading behind a
        // full-page error; it now shows the reading plus a compact warning
        // banner instead, since the cached data is still perfectly good.
        let reading = sampleReading(reportingAgency: "Bay Area Air District")
        let error = AQIFetchError.airNowError(.webServiceError(statusCode: 502, message: "upstream unavailable"))
        let image = render(
            AQIPopoverView(reading: reading, lastError: error, lastFetchedAt: Date(), onLocationChange: {})
        )
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithAnErrorAndNoReadingAtAll() {
        // The full-page ContentUnavailableView path e70.24 introduced still
        // exists -- just now only reached when there's truly no reading to
        // fall back on.
        let error = AQIFetchError.serviceModeRateLimited
        let image = render(
            AQIPopoverView(reading: nil, lastError: error, lastFetchedAt: nil, onLocationChange: {})
        )
        XCTAssertNotNil(image)
    }

    private func sampleReading(reportingAgency: String?) -> AQIReading {
        AQIReading(
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
                    reportingAgency: reportingAgency,
                    lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All",
                    lookupBoundary: "50 Miles"
                ),
            ]
        )
    }

    @MainActor
    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        return renderer.nsImage
    }
}
