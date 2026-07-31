import XCTest
@testable import BluegullAQIKit

final class AttributionCopyTests: XCTestCase {
    func testStaticCreditMentionsEPAAndAirNow() {
        // Regression test against accidental future edits dropping either
        // half of the required second-tier credit (bluegull-aqi-10h.15).
        XCTAssertTrue(AttributionCopy.staticCredit.contains("EPA"))
        XCTAssertTrue(AttributionCopy.staticCredit.contains("AirNow"))
    }

    func testPreliminaryDataDisclaimerMentionsPreliminary() {
        // Regression test against accidental future edits dropping the
        // required "preliminary" indication (bluegull-aqi-dc2.4).
        XCTAssertTrue(AttributionCopy.preliminaryDataDisclaimer.contains("preliminary"))
    }
}
