import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `AirNowAPIKeyEntryViewRenderTests`)
/// -- confirms the hidden dev-only override view renders without crashing,
/// both with nothing stored and with an existing override. Store-level
/// behavior (fallback logic) is covered in `BluegullAQIKitTests`; this just
/// confirms the view itself, which is otherwise only ever reachable through
/// `SettingsView`'s secret Option-click gesture.
final class DevServiceURLOverrideViewRenderTests: XCTestCase {
    /// A throwaway suite per test -- never the real App Group.
    private func makeScratchDefaults(_ name: String) throws -> UserDefaults {
        let suite = "test.devOverrideView.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testRendersWithoutCrashingWithNoStoredOverride() throws {
        let defaults = try makeScratchDefaults("empty")
        let renderer = ImageRenderer(content: DevServiceURLOverrideView(store: defaults))
        XCTAssertNotNil(renderer.nsImage)
    }

    @MainActor
    func testRendersWithoutCrashingWithAnExistingOverride() throws {
        let defaults = try makeScratchDefaults("existing")
        defaults.set("http://localhost:8080/dev", forKey: DevServiceURLOverrideStore.userDefaultsKey)
        let renderer = ImageRenderer(content: DevServiceURLOverrideView(store: defaults))
        XCTAssertNotNil(renderer.nsImage)
    }
}
