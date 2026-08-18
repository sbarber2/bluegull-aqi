import XCTest
import SwiftUI
@testable import BluegullAQI

/// Lightweight smoke test (same rationale/precedent as
/// `DataSourceModeToggleRenderTests`) -- confirms each stepper renders
/// without crashing. Doesn't assert on `@AppStorage`'s own persistence
/// behavior: that's Apple's own, already-tested framework code.
final class RequestTimeoutSteppersRenderTests: XCTestCase {
    @MainActor
    func testServiceTimeoutStepperRendersWithoutCrashing() {
        XCTAssertNotNil(ImageRenderer(content: ServiceTimeoutStepper()).nsImage)
    }

    @MainActor
    func testDirectTimeoutStepperRendersWithoutCrashing() {
        XCTAssertNotNil(ImageRenderer(content: DirectTimeoutStepper()).nsImage)
    }
}
