import XCTest
@testable import BluegullAQIKit

final class AttributionCopyTests: XCTestCase {
    func testStaticCreditMentionsEPAAndAirNow() {
        // Regression test against accidental future edits dropping either
        // half of the required second-tier credit (bluegull-aqi-10h.15).
        XCTAssertTrue(AttributionCopy.staticCredit.contains("EPA"))
        XCTAssertTrue(AttributionCopy.staticCredit.contains("AirNow"))
    }
}
