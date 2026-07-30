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
}
