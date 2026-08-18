import XCTest
@testable import BluegullAQIWidgetViews
import BluegullAQIKit

final class BluegullAQIWidgetEntryTests: XCTestCase {
    // bluegull-aqi-e70.27: `withResolvedPlaceName` is what
    // `BluegullAQIWidgetTimelineProvider` (untestable itself -- app-extension
    // targets can't be linked by a separate test target, same reasoning as
    // `WidgetTimelineComputer`'s own doc comment) uses to attach a
    // reverse-geocoded place name after the fact, alongside `locationName`
    // (not replacing it -- Steve wanted both visible).
    func testWithResolvedPlaceNameAttachesWithoutTouchingLocationName() {
        let reading = AQIReading(
            location: Location(latitude: 37.77, longitude: -122.42),
            pollutants: []
        )
        let original = BluegullAQIWidgetEntry(
            date: Date(timeIntervalSince1970: 1000),
            reading: reading,
            configuredLocation: nil,
            locationName: "Current Location",
            lastSuccessfulFetchDate: Date(timeIntervalSince1970: 900),
            freshness: .fresh
        )
        XCTAssertNil(original.resolvedPlaceName)

        let updated = original.withResolvedPlaceName("San Francisco, CA")

        XCTAssertEqual(updated.resolvedPlaceName, "San Francisco, CA")
        XCTAssertEqual(updated.locationName, "Current Location")
        XCTAssertEqual(updated.date, original.date)
        XCTAssertEqual(updated.reading, original.reading)
        XCTAssertEqual(updated.configuredLocation, original.configuredLocation)
        XCTAssertEqual(updated.lastSuccessfulFetchDate, original.lastSuccessfulFetchDate)
        XCTAssertEqual(updated.freshness, original.freshness)
    }
}
