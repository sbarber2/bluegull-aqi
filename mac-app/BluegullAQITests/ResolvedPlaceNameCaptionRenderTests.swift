import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as sibling render-test suites in
/// this target) -- confirms `ResolvedPlaceNameCaption` renders without
/// crashing both when reverse geocoding succeeds and when it fails and the
/// view falls back to raw coordinates.
final class ResolvedPlaceNameCaptionRenderTests: XCTestCase {
    private let sampleLocation = Location(latitude: 37.77, longitude: -122.42)

    @MainActor
    func testRendersWithoutCrashingWhenResolved() {
        let view = ResolvedPlaceNameCaption(
            location: sampleLocation,
            resolver: .fake(reverseGeocoding: .success("San Francisco, CA"))
        )
        XCTAssertNotNil(ImageRenderer(content: view).nsImage)
    }

    @MainActor
    func testRendersWithoutCrashingWhenReverseGeocodingFails() {
        let view = ResolvedPlaceNameCaption(
            location: sampleLocation,
            resolver: .fake(reverseGeocoding: .failure(.noResults))
        )
        XCTAssertNotNil(ImageRenderer(content: view).nsImage)
    }
}
