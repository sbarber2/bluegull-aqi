import XCTest
import SwiftUI
import WidgetKit
@testable import BluegullAQIWidgetViews
import BluegullAQIKit

/// Confirms each per-family layout renders without crashing, same
/// ImageRenderer-based convention already used for the container app's own
/// views (e.g. `AQIPopoverViewRenderTests`) -- possible at all now that
/// `BluegullAQIWidgetView` lives in this normal library target rather than
/// the `BluegullAQIWidget` app-extension target, which can't be linked by a
/// separate test target (bluegull-aqi-mtm.10; see
/// `WidgetTimelineComputer`'s own doc comment for the confirmed build
/// error this works around).
final class BluegullAQIWidgetViewRenderTests: XCTestCase {
    @MainActor
    func testSmallLayoutRendersWithoutCrashing() {
        XCTAssertNotNil(renderedImage(for: sampleEntry(), family: .systemSmall))
    }

    @MainActor
    func testMediumLayoutRendersWithoutCrashing() {
        XCTAssertNotNil(renderedImage(for: sampleEntry(), family: .systemMedium))
    }

    @MainActor
    func testLargeLayoutRendersWithoutCrashing() {
        XCTAssertNotNil(renderedImage(for: sampleEntry(), family: .systemLarge))
    }

    @MainActor
    func testNoDataStateRendersWithoutCrashingForEveryFamily() {
        let entry = BluegullAQIWidgetEntry(date: Date(), reading: nil)
        for family: WidgetFamily in [.systemSmall, .systemMedium, .systemLarge] {
            XCTAssertNotNil(renderedImage(for: entry, family: family))
        }
    }

    // bluegull-aqi-dc2.6: freshness == .stale still renders (in all three
    // layouts) rather than crashing when the aged indicator is added.
    @MainActor
    func testAgedReadingStateRendersWithoutCrashingForEveryFamily() {
        let entry = sampleEntry(freshness: .stale)
        for family: WidgetFamily in [.systemSmall, .systemMedium, .systemLarge] {
            XCTAssertNotNil(renderedImage(for: entry, family: family))
        }
    }

    private func sampleEntry(freshness: AQIFreshness? = nil) -> BluegullAQIWidgetEntry {
        let location = Location(latitude: 37.77, longitude: -122.42)
        let reading = AQIReading(
            location: location,
            pollutants: [
                PollutantReading(
                    dateObserved: "2026-07-30",
                    hourObserved: "14",
                    localTimeZone: "PDT",
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
                ),
            ]
        )
        return BluegullAQIWidgetEntry(date: Date(), reading: reading, configuredLocation: location, freshness: freshness)
    }

    @MainActor
    private func renderedImage(for entry: BluegullAQIWidgetEntry, family: WidgetFamily) -> CGImage? {
        let view = BluegullAQIWidgetView(entry: entry, familyOverride: family)
            .frame(width: 158, height: 158)
        let renderer = ImageRenderer(content: view)
        return renderer.cgImage
    }
}
