import XCTest
import SwiftUI
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `DataSourceModeToggleRenderTests`)
/// -- confirms the toggle renders without crashing. Doesn't exercise the
/// actual `SMAppService.mainApp.register()`/`unregister()` calls: those only
/// run from the Binding's `set`, which rendering alone never triggers, and
/// asserting on `SMAppService`'s own registration behavior would mean
/// actually registering/unregistering a real login item as a side effect of
/// running this test suite -- not something a unit test should do.
final class LaunchAtLoginToggleRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashing() {
        let renderer = ImageRenderer(content: LaunchAtLoginToggle())
        XCTAssertNotNil(renderer.nsImage)
    }
}
