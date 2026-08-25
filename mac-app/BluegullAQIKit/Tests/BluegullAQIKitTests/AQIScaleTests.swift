import XCTest
@testable import BluegullAQIKit

final class AQIScaleTests: XCTestCase {
    func testBreakpointsLandExactlyOnTheDesignedFractions() {
        XCTAssertEqual(AQIScale.fraction(forAQI: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 50), 0.15, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 100), 0.30, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 150), 0.45, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 200), 0.60, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 300), 0.85, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 500), 1.0, accuracy: 0.0001)
    }

    func testInterpolatesLinearlyWithinABand() {
        // Midpoint of the 0...50 band (Good) should land halfway between
        // its fraction endpoints.
        XCTAssertEqual(AQIScale.fraction(forAQI: 25), 0.075, accuracy: 0.0001)
        // Midpoint of the 200...300 band (Very Unhealthy).
        XCTAssertEqual(AQIScale.fraction(forAQI: 250), 0.725, accuracy: 0.0001)
    }

    func testValuesAboveFiveHundredClampToTheEndOfTheBar() {
        // Real, AirNow-supplied data (AQICategory.beyondAQI) -- must not
        // crash or extrapolate past the bar's own end.
        XCTAssertEqual(AQIScale.fraction(forAQI: 750), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AQIScale.fraction(forAQI: 999), 1.0, accuracy: 0.0001)
    }

    func testNegativeValuesClampToTheStartOfTheBar() {
        // AQICategory itself treats negative as malformed data (returns
        // nil), but this type has no such escape hatch -- it must still
        // produce something sane rather than crash if ever called with one.
        XCTAssertEqual(AQIScale.fraction(forAQI: -10), 0, accuracy: 0.0001)
    }

    func testFractionIsMonotonicallyNondecreasing() {
        var previous = -1.0
        for aqi in stride(from: 0, through: 500, by: 5) {
            let fraction = AQIScale.fraction(forAQI: aqi)
            XCTAssertGreaterThanOrEqual(fraction, previous, "fraction decreased at aqi=\(aqi)")
            previous = fraction
        }
    }
}
