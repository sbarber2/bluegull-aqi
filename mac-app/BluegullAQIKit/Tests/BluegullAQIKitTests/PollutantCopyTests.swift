import XCTest
@testable import BluegullAQIKit

final class PollutantCopyTests: XCTestCase {
    func testPM25UsesParticlePollutionNotParticulateMatter() {
        XCTAssertEqual(PollutantCopy.spelledOutName(forParameterName: "PM2.5"), "Particle Pollution (PM2.5)")
    }

    func testPM10UsesParticlePollutionNotParticulateMatter() {
        XCTAssertEqual(PollutantCopy.spelledOutName(forParameterName: "PM10"), "Particle Pollution (PM10)")
    }

    func testUnmappedPollutantFallsBackToRawParameterName() {
        // Deliberately narrow scope (bluegull-aqi-10h.20): no invented
        // translation for pollutants this issue didn't ask about.
        XCTAssertEqual(PollutantCopy.spelledOutName(forParameterName: "OZONE"), "OZONE")
        XCTAssertEqual(PollutantCopy.spelledOutName(forParameterName: "CO"), "CO")
    }
}
