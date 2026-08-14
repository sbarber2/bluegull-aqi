import XCTest
@testable import BluegullAQIKit

final class DevServiceURLOverrideStoreTests: XCTestCase {
    private let fallback = URL(string: "https://dev.aqi.bluegull.solutions/aqi")!

    /// A throwaway suite per test -- never the real App Group, same
    /// reasoning as `DataSourceModeTests`'s own scratch-defaults helper.
    private func makeScratchDefaults(_ name: String) throws -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFallsBackToFallbackWhenUnset() throws {
        let defaults = try makeScratchDefaults("unset")
        XCTAssertEqual(DevServiceURLOverrideStore.resolvedBaseURL(fallback: fallback, in: defaults), fallback)
    }

    func testFallsBackToFallbackWhenStoredValueIsEmpty() throws {
        let defaults = try makeScratchDefaults("empty")
        defaults.set("", forKey: DevServiceURLOverrideStore.userDefaultsKey)
        XCTAssertEqual(DevServiceURLOverrideStore.resolvedBaseURL(fallback: fallback, in: defaults), fallback)
    }

    func testUsesStoredOverrideWhenValid() throws {
        let defaults = try makeScratchDefaults("valid")
        defaults.set("http://localhost:8080/dev", forKey: DevServiceURLOverrideStore.userDefaultsKey)
        XCTAssertEqual(
            DevServiceURLOverrideStore.resolvedBaseURL(fallback: fallback, in: defaults),
            URL(string: "http://localhost:8080/dev")!
        )
    }

    func testFallsBackToFallbackWhenTheSuiteIsUnavailable() {
        XCTAssertEqual(DevServiceURLOverrideStore.resolvedBaseURL(fallback: fallback, in: nil), fallback)
    }
}
