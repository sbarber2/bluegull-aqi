import XCTest
@testable import BluegullAQIKit

final class DataSourceModeTests: XCTestCase {
    func testDefaultModeIsService() {
        // bluegull-aqi-8ef.2, DECIDED 2026-07-30: Service mode, not Direct.
        XCTAssertEqual(DataSourceModeStore.defaultMode, .service)
    }

    func testRawValuesRoundTripForAppStorage() {
        // @AppStorage (bluegull-aqi-e70.3) persists via the RawRepresentable
        // conformance -- a regression test against accidentally breaking
        // that round trip (e.g. renaming a case without updating rawValue).
        for mode in DataSourceMode.allCases {
            XCTAssertEqual(DataSourceMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - App Group-backed storage (bluegull-aqi-mtm.24)

    /// A throwaway suite per test -- never the real App Group, so these
    /// can't disturb an actual install's setting.
    private func makeScratchDefaults(_ name: String) throws -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testCurrentModeFallsBackToDefaultWhenUnset() throws {
        let defaults = try makeScratchDefaults("unset")
        XCTAssertEqual(DataSourceModeStore.currentMode(in: defaults), .service)
    }

    func testCurrentModeReadsAStoredSelection() throws {
        let defaults = try makeScratchDefaults("stored")
        defaults.set(DataSourceMode.direct.rawValue, forKey: DataSourceModeStore.userDefaultsKey)
        XCTAssertEqual(DataSourceModeStore.currentMode(in: defaults), .direct)
    }

    func testCurrentModeFallsBackToDefaultOnAnUnrecognizedValue() throws {
        let defaults = try makeScratchDefaults("garbage")
        defaults.set("carrier-pigeon", forKey: DataSourceModeStore.userDefaultsKey)
        XCTAssertEqual(DataSourceModeStore.currentMode(in: defaults), .service)
    }

    func testCurrentModeFallsBackToDefaultWhenTheSuiteIsUnavailable() {
        // nil `sharedDefaults` (App Group unopenable) must not trap.
        XCTAssertEqual(DataSourceModeStore.currentMode(in: nil), .service)
    }

    /// The point of the migration: a user who explicitly chose Direct mode
    /// before this setting moved into the App Group must not silently
    /// revert to the Service default on first launch after updating.
    func testMigrationMovesAnExistingChoiceOutOfStandardDefaults() throws {
        let standard = try makeScratchDefaults("legacy")
        let shared = try makeScratchDefaults("shared")
        standard.set(DataSourceMode.direct.rawValue, forKey: DataSourceModeStore.userDefaultsKey)

        DataSourceModeStore.migrateFromStandardIfNeeded(standard: standard, shared: shared)

        XCTAssertEqual(DataSourceModeStore.currentMode(in: shared), .direct)
        XCTAssertNil(standard.string(forKey: DataSourceModeStore.userDefaultsKey))
    }

    func testMigrationDoesNotOverwriteAnExistingSharedChoice() throws {
        let standard = try makeScratchDefaults("legacy2")
        let shared = try makeScratchDefaults("shared2")
        standard.set(DataSourceMode.service.rawValue, forKey: DataSourceModeStore.userDefaultsKey)
        shared.set(DataSourceMode.direct.rawValue, forKey: DataSourceModeStore.userDefaultsKey)

        DataSourceModeStore.migrateFromStandardIfNeeded(standard: standard, shared: shared)

        XCTAssertEqual(DataSourceModeStore.currentMode(in: shared), .direct)
    }

    func testMigrationIsANoOpWhenNothingWasEverStored() throws {
        let standard = try makeScratchDefaults("legacy3")
        let shared = try makeScratchDefaults("shared3")

        DataSourceModeStore.migrateFromStandardIfNeeded(standard: standard, shared: shared)

        XCTAssertNil(shared.string(forKey: DataSourceModeStore.userDefaultsKey))
        XCTAssertEqual(DataSourceModeStore.currentMode(in: shared), .service)
    }
}
