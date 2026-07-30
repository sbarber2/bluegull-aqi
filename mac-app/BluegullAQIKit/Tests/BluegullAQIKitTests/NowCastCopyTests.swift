import XCTest
@testable import BluegullAQIKit

final class NowCastCopyTests: XCTestCase {
    func testHeadlineMatchesAirNowsOwnPhrasing() {
        // Verified against the live airnow.gov site (see doc/DESIGN.md) --
        // safe because it doesn't imply an instantaneous spot reading.
        XCTAssertEqual(NowCastCopy.headline, "Current Air Quality")
    }
}
