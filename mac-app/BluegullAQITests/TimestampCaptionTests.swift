import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// `TimestampCaption.absoluteText(for:in:)` is a plain String-returning
/// static func (exposed specifically for this), so its format/precision is
/// tested directly here -- same reasoning as
/// `PollutantReading.observedAtDisplay`'s own tests -- rather than only
/// through an ImageRenderer smoke test, which could only prove "renders",
/// not "renders the right string" (bluegull-aqi-e70.48's acceptance
/// criteria explicitly asks for the former).
final class TimestampCaptionTests: XCTestCase {
    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, timeZone: TimeZone) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)!
    }

    func testAbsoluteTextIncludesSecondResolution() {
        let date = makeDate(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 7, timeZone: TimeZone(abbreviation: "EDT")!)
        let text = TimestampCaption.absoluteText(for: date, in: TimeZone(abbreviation: "EDT")!)
        XCTAssertEqual(text, "Wed Aug 12, 2026, 5:00:07 PM EDT")
    }

    func testAbsoluteTextReflectsTheSuppliedTimeZoneNotTheDevicesOwn() {
        // Same instant, formatted in two different zones -- confirms
        // `timeZone` actually drives the output rather than the formatter
        // silently falling back to `.current` or a fixed one.
        let date = makeDate(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 0, timeZone: TimeZone(abbreviation: "EDT")!)
        let pacific = TimestampCaption.absoluteText(for: date, in: TimeZone(abbreviation: "PDT")!)
        XCTAssertEqual(pacific, "Wed Aug 12, 2026, 2:00:00 PM PDT")
    }

    func testAbsoluteTextIsStableAcrossLocaleRegardlessOfSystemLocale() {
        // Fixed en_US formatting (bluegull-aqi-e70.48, matching
        // observedAtDisplay's own determinism reasoning) -- this doesn't
        // vary with whatever locale the test happens to run under.
        let date = makeDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, timeZone: TimeZone(abbreviation: "UTC")!)
        let text = TimestampCaption.absoluteText(for: date, in: TimeZone(abbreviation: "UTC")!)
        // Foundation's own quirk, not this code's: TimeZone(abbreviation:
        // "UTC")'s own `.abbreviation()` renders as "GMT", not "UTC".
        XCTAssertEqual(text, "Thu Jan 1, 2026, 12:00:00 AM GMT")
    }

    @MainActor
    func testRendersWithoutCrashing() {
        let date = makeDate(year: 2026, month: 8, day: 12, hour: 17, minute: 0, second: 0, timeZone: .current)
        XCTAssertNotNil(
            ImageRenderer(content: TimestampCaption(label: "Observed", date: date, timeZone: .current)).nsImage
        )
    }
}
