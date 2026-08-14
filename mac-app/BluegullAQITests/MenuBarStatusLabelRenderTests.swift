import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `AQIPopoverViewRenderTests`) --
/// confirms `MenuBarStatusLabel` renders without crashing in both of its
/// `@AppStorage`-driven styles (bluegull-aqi-e70.26), plus its pre-existing
/// fresh/stale/no-reading states. Not a golden-image regression suite like
/// the widget's (bluegull-aqi-mtm.11) -- `NSStatusItem`-hosted content isn't
/// reachable through the same headless `ImageRenderer` sizing that harness
/// relies on, since a real menu bar clamps status-item height itself; actual
/// visual confirmation is manual (Steve running the app), not this test.
final class MenuBarStatusLabelRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashingWithColorPillEnabled() {
        let image = render(MenuBarStatusLabel(reading: sampleReading, freshness: .fresh), colorPillEnabled: true)
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithColorPillDisabled() {
        let image = render(MenuBarStatusLabel(reading: sampleReading, freshness: .fresh), colorPillEnabled: false)
        XCTAssertNotNil(image)
    }

    // bluegull-aqi-e70.29: both styling paths (pill and plain dot) route
    // the AQI label through separately -- confirms each renders with it on.
    @MainActor
    func testRendersWithoutCrashingWithAQILabelEnabledAndColorPill() {
        let image = render(MenuBarStatusLabel(reading: sampleReading, freshness: .fresh), colorPillEnabled: true, aqiLabelEnabled: true)
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWithAQILabelEnabledAndPlainDot() {
        let image = render(MenuBarStatusLabel(reading: sampleReading, freshness: .fresh), colorPillEnabled: false, aqiLabelEnabled: true)
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWhenStale() {
        // bluegull-aqi-e70.31: a stale reading falls back to the icon+dash,
        // neither styling applies -- confirms that path still renders too.
        let image = render(MenuBarStatusLabel(reading: sampleReading, freshness: .stale), colorPillEnabled: true)
        XCTAssertNotNil(image)
    }

    @MainActor
    func testRendersWithoutCrashingWhenNoReading() {
        let image = render(MenuBarStatusLabel(reading: nil, freshness: nil), colorPillEnabled: true)
        XCTAssertNotNil(image)
    }

    private var sampleReading: AQIReading {
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
                    nowcastAQI: 78,
                    aqiCategoryName: "Moderate",
                    reportingAgency: "Bay Area Air District",
                    lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All",
                    lookupBoundary: "50 Miles"
                ),
            ]
        )
    }

    // Saves/restores the real key around each render -- `@AppStorage`
    // without an explicit `store:` always reads `UserDefaults.standard`
    // (matching `MenuBarStatusLabel`'s own, since this preference has no
    // App Group/widget consumer -- see `MenuBarAppearanceStore`'s doc
    // comment), so there's no separate suite to isolate into instead.
    @MainActor
    private func render(_ view: some View, colorPillEnabled: Bool, aqiLabelEnabled: Bool = false) -> NSImage? {
        let defaults = UserDefaults.standard
        let originalColorPillValue = defaults.object(forKey: MenuBarAppearanceStore.colorPillEnabledKey)
        let originalAQILabelValue = defaults.object(forKey: MenuBarAppearanceStore.aqiLabelEnabledKey)
        defer {
            restore(originalColorPillValue, forKey: MenuBarAppearanceStore.colorPillEnabledKey)
            restore(originalAQILabelValue, forKey: MenuBarAppearanceStore.aqiLabelEnabledKey)
        }
        defaults.set(colorPillEnabled, forKey: MenuBarAppearanceStore.colorPillEnabledKey)
        defaults.set(aqiLabelEnabled, forKey: MenuBarAppearanceStore.aqiLabelEnabledKey)
        let renderer = ImageRenderer(content: view)
        return renderer.nsImage
    }

    private func restore(_ originalValue: Any?, forKey key: String) {
        if let originalValue {
            UserDefaults.standard.set(originalValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
