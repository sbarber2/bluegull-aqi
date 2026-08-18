import XCTest
@testable import BluegullAQIKit

final class RequestTimeoutStoreTests: XCTestCase {
    /// A throwaway suite per test -- never the real App Group, same
    /// reasoning as `DataSourceModeTests`'s own scratch-defaults helper.
    private func makeScratchDefaults(_ name: String) throws -> UserDefaults {
        let suite = "test.requestTimeout.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDirectTimeoutFallsBackToDefaultWhenUnset() throws {
        let defaults = try makeScratchDefaults("direct-unset")
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: defaults), RequestTimeoutStore.defaultDirectTimeout)
    }

    func testServiceTimeoutFallsBackToDefaultWhenUnset() throws {
        let defaults = try makeScratchDefaults("service-unset")
        XCTAssertEqual(RequestTimeoutStore.serviceTimeout(in: defaults), RequestTimeoutStore.defaultServiceTimeout)
    }

    // The actual point of this whole feature (bluegull-aqi-e70.43): Service
    // mode's default is now 15s, up from the shared 10s both used before.
    func testDefaultServiceTimeoutIsFifteenSeconds() {
        XCTAssertEqual(RequestTimeoutStore.defaultServiceTimeout, 15)
    }

    func testDefaultDirectTimeoutIsUnchangedAtTenSeconds() {
        XCTAssertEqual(RequestTimeoutStore.defaultDirectTimeout, 10)
    }

    func testDirectTimeoutReadsAStoredValue() throws {
        let defaults = try makeScratchDefaults("direct-stored")
        defaults.set(20.0, forKey: RequestTimeoutStore.directUserDefaultsKey)
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: defaults), 20)
    }

    func testServiceTimeoutReadsAStoredValue() throws {
        let defaults = try makeScratchDefaults("service-stored")
        defaults.set(30.0, forKey: RequestTimeoutStore.serviceUserDefaultsKey)
        XCTAssertEqual(RequestTimeoutStore.serviceTimeout(in: defaults), 30)
    }

    // Defense-in-depth against a corrupted/hand-edited plist value -- the
    // Settings stepper itself can never produce an out-of-range value, but
    // this function doesn't trust that's the only writer.
    func testOutOfRangeStoredValueFallsBackToDefault() throws {
        let defaults = try makeScratchDefaults("direct-out-of-range")
        defaults.set(9999.0, forKey: RequestTimeoutStore.directUserDefaultsKey)
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: defaults), RequestTimeoutStore.defaultDirectTimeout)
    }

    func testZeroStoredValueFallsBackToDefault() throws {
        let defaults = try makeScratchDefaults("direct-zero")
        defaults.set(0.0, forKey: RequestTimeoutStore.directUserDefaultsKey)
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: defaults), RequestTimeoutStore.defaultDirectTimeout)
    }

    func testFallsBackToDefaultWhenTheSuiteIsUnavailable() {
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: nil), RequestTimeoutStore.defaultDirectTimeout)
        XCTAssertEqual(RequestTimeoutStore.serviceTimeout(in: nil), RequestTimeoutStore.defaultServiceTimeout)
    }

    func testDirectAndServiceTimeoutsAreIndependent() throws {
        let defaults = try makeScratchDefaults("independent")
        defaults.set(25.0, forKey: RequestTimeoutStore.directUserDefaultsKey)
        XCTAssertEqual(RequestTimeoutStore.directTimeout(in: defaults), 25)
        XCTAssertEqual(RequestTimeoutStore.serviceTimeout(in: defaults), RequestTimeoutStore.defaultServiceTimeout)
    }
}
