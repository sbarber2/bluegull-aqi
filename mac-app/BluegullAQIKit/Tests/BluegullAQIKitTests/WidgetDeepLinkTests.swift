import XCTest
@testable import BluegullAQIKit

final class WidgetDeepLinkTests: XCTestCase {
    func testRoundTripsARealLocation() {
        let location = Location(latitude: 37.7749, longitude: -122.4194)
        let url = WidgetDeepLink.url(for: location)

        XCTAssertEqual(WidgetDeepLink.location(from: url), location)
    }

    func testNilLocationEncodesWithNoQueryItemsAndDecodesBackToNil() {
        let url = WidgetDeepLink.url(for: nil)

        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertNil(WidgetDeepLink.location(from: url))
    }

    func testUsesTheExpectedSchemeAndHost() {
        let url = WidgetDeepLink.url(for: nil)

        XCTAssertEqual(url.scheme, "bluegullaqi")
        XCTAssertEqual(url.host, "widget-detail")
    }

    func testLocationFromURLIsNilForAForeignURL() {
        XCTAssertNil(WidgetDeepLink.location(from: URL(string: "https://example.com")!))
    }

    func testLocationFromURLIsNilWhenOnlyLatitudeIsPresent() {
        var components = URLComponents()
        components.scheme = WidgetDeepLink.scheme
        components.host = WidgetDeepLink.host
        components.queryItems = [URLQueryItem(name: "lat", value: "37.77")]

        XCTAssertNil(WidgetDeepLink.location(from: components.url!))
    }

    func testLocationFromURLIsNilForNonNumericValues() {
        var components = URLComponents()
        components.scheme = WidgetDeepLink.scheme
        components.host = WidgetDeepLink.host
        components.queryItems = [
            URLQueryItem(name: "lat", value: "not-a-number"),
            URLQueryItem(name: "lon", value: "-122.42"),
        ]

        XCTAssertNil(WidgetDeepLink.location(from: components.url!))
    }
}
