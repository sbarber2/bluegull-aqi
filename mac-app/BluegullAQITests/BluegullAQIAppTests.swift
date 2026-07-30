import XCTest
@testable import BluegullAQIKit

final class BluegullAQIAppTests: XCTestCase {
    func testPackageDependencyIsWiredUp() {
        XCTAssertEqual(NowCastCopy.headline, "Current Air Quality")
    }
}
