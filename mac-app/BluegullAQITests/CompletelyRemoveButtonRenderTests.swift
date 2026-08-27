import XCTest
import SwiftUI
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `LaunchAtLoginToggleRenderTests`)
/// -- confirms the button renders without crashing. Doesn't exercise
/// `performRemoval()`, which only runs from the confirmation dialog's
/// destructive action -- rendering alone never triggers it, and actually
/// wiping this test process's own UserDefaults/Keychain state as a side
/// effect of a unit test would be exactly the kind of real, persistent
/// side effect a test must not have.
final class CompletelyRemoveButtonRenderTests: XCTestCase {
    @MainActor
    func testRendersWithoutCrashing() {
        let renderer = ImageRenderer(content: CompletelyRemoveButton())
        XCTAssertNotNil(renderer.nsImage)
    }
}
