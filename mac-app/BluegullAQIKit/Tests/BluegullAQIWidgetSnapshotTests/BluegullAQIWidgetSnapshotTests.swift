import XCTest
import SwiftUI
import WidgetKit
@testable import BluegullAQIWidgetViews
import BluegullAQIKit

/// Golden-image regression coverage for the widget's per-family layouts
/// (bluegull-aqi-mtm.11), covering the failure modes the issue calls out
/// by name:
/// - AQI 500 vs 5 (digit count changing layout) --
///   `testSmallLowAQI`/`testSmallHazardousAQI`/`testSmallBeyondScaleAQI`.
/// - Full pollutant breakdown overflowing the large widget --
///   `testLargeManyPollutants`.
/// - Missing-data states -- `test*NoData` (never fetched) vs. `test*StaleData`
///   (a fetch succeeded at some point, but that entry's since expired --
///   bluegull-aqi-dc2.1's distinct visual state, driven by
///   `AppGroupCache.lastSuccessfulFetchDate()` surviving the per-location
///   entry's own TTL expiry).
/// - Light/dark mode -- `testLargeTypicalDarkMode`.
///
/// Deliberately NOT covered here: Dynamic Type. `ImageRenderer` does not
/// honor `.environment(\.dynamicTypeSize, ...)` at all on this platform --
/// confirmed with an isolated repro independent of this codebase (a bare
/// `Text("x").font(.caption)` renders byte-identical PNGs regardless of the
/// override, while the same pipeline's `colorScheme` override does work, per
/// `testLargeTypicalDarkMode`). A prior version of this file had a
/// `testLargeTypicalAccessibilityDynamicType` snapshot test that could never
/// actually fail, since its golden image was always identical to
/// `large-typical`'s -- pure false confidence, removed in
/// bluegull-aqi-mtm.17. The widget layouts now use `@ScaledMetric` for their
/// headline AQI number font (see `BluegullAQIWidgetView.swift`), which *does*
/// respond to Dynamic Type on a real widget host -- just not verifiable
/// through this harness. Real verification is manual, folded into
/// bluegull-aqi-mtm.9.
///
/// First run (or after an intentional visual change) needs
/// `RECORD_SNAPSHOTS=1 swift test --filter BluegullAQIWidgetSnapshotTests`
/// to (re)write the golden PNGs in `__Snapshots__/` before a normal run can
/// compare against them.
final class BluegullAQIWidgetSnapshotTests: XCTestCase {
    private static let smallSize = CGSize(width: 158, height: 158)
    private static let mediumSize = CGSize(width: 338, height: 158)
    private static let largeSize = CGSize(width: 338, height: 358)

    @MainActor
    func testSmallLowAQI() {
        let entry = entry(withPollutants: [pollutant("OZONE", aqi: 5, category: "Good")])
        assertSnapshot(entry, family: .systemSmall, size: Self.smallSize, name: "small-low-aqi")
    }

    @MainActor
    func testSmallHazardousAQI() {
        let entry = entry(withPollutants: [pollutant("PM2.5", aqi: 500, category: "Hazardous")])
        assertSnapshot(entry, family: .systemSmall, size: Self.smallSize, name: "small-hazardous-aqi")
    }

    @MainActor
    func testSmallBeyondScaleAQI() {
        let entry = entry(withPollutants: [pollutant("PM2.5", aqi: 550, category: "Hazardous")])
        assertSnapshot(entry, family: .systemSmall, size: Self.smallSize, name: "small-beyond-scale-aqi")
    }

    @MainActor
    func testSmallNoData() {
        assertSnapshot(entry(reading: nil), family: .systemSmall, size: Self.smallSize, name: "small-no-data")
    }

    @MainActor
    func testSmallStaleData() {
        assertSnapshot(staleEntry, family: .systemSmall, size: Self.smallSize, name: "small-stale-data")
    }

    @MainActor
    func testMediumTypical() {
        let entry = entry(withPollutants: [
            pollutant("PM2.5", aqi: 78, category: "Moderate"),
            pollutant("OZONE", aqi: 42, category: "Good"),
            pollutant("PM10", aqi: 15, category: "Good"),
        ])
        assertSnapshot(entry, family: .systemMedium, size: Self.mediumSize, name: "medium-typical")
    }

    @MainActor
    func testMediumOnlyHeadlinePollutant() {
        // No "other pollutants" to show alongside the headline -- the
        // divider/second column shouldn't appear at all.
        let entry = entry(withPollutants: [pollutant("PM2.5", aqi: 78, category: "Moderate")])
        assertSnapshot(entry, family: .systemMedium, size: Self.mediumSize, name: "medium-only-headline-pollutant")
    }

    @MainActor
    func testMediumNoData() {
        assertSnapshot(entry(reading: nil), family: .systemMedium, size: Self.mediumSize, name: "medium-no-data")
    }

    @MainActor
    func testMediumStaleData() {
        assertSnapshot(staleEntry, family: .systemMedium, size: Self.mediumSize, name: "medium-stale-data")
    }

    @MainActor
    func testLargeTypical() {
        assertSnapshot(typicalLargeEntry, family: .systemLarge, size: Self.largeSize, name: "large-typical")
    }

    @MainActor
    func testLargeManyPollutants() {
        // Every AirNow "criteria pollutant" AQI-eligible parameter at once --
        // the full-breakdown overflow case the issue calls out by name.
        let entry = entry(withPollutants: [
            pollutant("PM2.5", aqi: 168, category: "Unhealthy"),
            pollutant("PM10", aqi: 92, category: "Moderate"),
            pollutant("OZONE", aqi: 55, category: "Moderate"),
            pollutant("CO", aqi: 12, category: "Good"),
            pollutant("SO2", aqi: 8, category: "Good"),
            pollutant("NO2", aqi: 21, category: "Good"),
        ])
        assertSnapshot(entry, family: .systemLarge, size: Self.largeSize, name: "large-many-pollutants")
    }

    @MainActor
    func testLargeNoData() {
        assertSnapshot(entry(reading: nil), family: .systemLarge, size: Self.largeSize, name: "large-no-data")
    }

    @MainActor
    func testLargeStaleData() {
        assertSnapshot(staleEntry, family: .systemLarge, size: Self.largeSize, name: "large-stale-data")
    }

    @MainActor
    func testLargeTypicalDarkMode() {
        // The production view's `.containerBackground(.background, for:
        // .widget)` (bluegull-aqi-mtm.11's real widget-code fix) only paints
        // when hosted by actual WidgetKit machinery -- confirmed by a real
        // capture: without an explicit fill here, this test's `.dark`
        // override left `.primary`-colored text invisible (white-on-
        // nothing) against ImageRenderer's default canvas. A real widget
        // host draws the appropriate dark chrome around the same view;
        // this fill exists only so the golden image itself is legible.
        let view = BluegullAQIWidgetView(entry: typicalLargeEntry, familyOverride: .systemLarge)
            .environment(\.colorScheme, .dark)
            .background(Color.black)
        GoldenImageAssertion.assert(view, named: "large-typical-dark", size: Self.largeSize)
    }

    // MARK: - Fixtures

    private var typicalLargeEntry: BluegullAQIWidgetEntry {
        entry(withPollutants: [
            pollutant("PM2.5", aqi: 78, category: "Moderate"),
            pollutant("OZONE", aqi: 42, category: "Good"),
            pollutant("PM10", aqi: 15, category: "Good"),
        ])
    }

    @MainActor
    private func assertSnapshot(_ entry: BluegullAQIWidgetEntry, family: WidgetFamily, size: CGSize, name: String) {
        let view = BluegullAQIWidgetView(entry: entry, familyOverride: family)
        GoldenImageAssertion.assert(view, named: name, size: size)
    }

    private func entry(reading: AQIReading?) -> BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(date: fixedDate, reading: reading)
    }

    // A prior fetch succeeded (3 hours before `fixedDate`, deterministically
    // formatted via en_US RelativeDateTimeFormatter -- see
    // BluegullAQIWidgetView's own `staleCaption`), but that entry has since
    // expired, so `reading` is nil same as the "never fetched" case.
    private var staleEntry: BluegullAQIWidgetEntry {
        BluegullAQIWidgetEntry(
            date: fixedDate,
            reading: nil,
            lastSuccessfulFetchDate: fixedDate.addingTimeInterval(-3 * 3600)
        )
    }

    private func entry(withPollutants pollutants: [PollutantReading]) -> BluegullAQIWidgetEntry {
        let location = Location(latitude: 37.7749, longitude: -122.4194)
        let reading = AQIReading(location: location, pollutants: pollutants)
        return BluegullAQIWidgetEntry(date: fixedDate, reading: reading, configuredLocation: location)
    }

    private func pollutant(_ parameterName: String, aqi: Int, category: String) -> PollutantReading {
        PollutantReading(
            dateObserved: "2026-07-30",
            hourObserved: "14",
            localTimeZone: "PDT",
            reportingAreaName: "San Francisco",
            siteID: "060750005",
            siteName: "San Francisco",
            parameterName: parameterName,
            nowcastAQI: aqi,
            aqiCategoryName: category,
            reportingAgency: "Bay Area Air District",
            lookupBehavior: "Closest Reading By Pollutant",
            consideredMonitors: "All",
            lookupBoundary: "50 Miles"
        )
    }

    // Fixed, not `Date()` -- the entry's `date` isn't rendered by any
    // current layout, but pinning it keeps these fixtures fully
    // deterministic regardless.
    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_785_000_000)
    }
}
