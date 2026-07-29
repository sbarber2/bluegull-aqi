import XCTest
@testable import BluegullAQIKit

final class BluegullAQIKitTests: XCTestCase {
    func testVersionIsSet() throws {
        XCTAssertFalse(BluegullAQIKit.version.isEmpty)
    }
}
