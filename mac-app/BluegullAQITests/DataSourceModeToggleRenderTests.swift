import XCTest
import SwiftUI
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `AQIPopoverViewRenderTests`) --
/// confirms the toggle actually renders without crashing. Doesn't assert on
/// `@AppStorage`'s persistence behavior itself: that's Apple's own,
/// already-tested framework code, not custom logic here.
final class DataSourceModeToggleRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashing() {
        let renderer = ImageRenderer(content: DataSourceModeToggle())
        XCTAssertNotNil(renderer.nsImage)
    }
}
