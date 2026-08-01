import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-10h.8: proves the design claim that callers "don't care
/// which source answered" -- AirNowDirectClient and BluegullServiceClient
/// wrap the exact same pollutant fixture in each API's own envelope shape
/// (a bare array vs. `{"observations": [...], "cached": bool}`) and must
/// decode to identical `AQIReading` values. If this test ever needs a
/// special case to pass, that's a sign the two clients have drifted from a
/// shared contract, not a good reason to relax the assertion.
final class ClientContractTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)
    private let fakeKey = "not-a-real-airnow-key-0000000000000000"

    private let pollutantFixtureJSON = """
    {
        "dateObserved": "2026-07-29",
        "hourObserved": "14:00",
        "localTimeZone": "PDT",
        "reportingAreaName": "San Francisco",
        "siteID": "060750005",
        "siteName": "San Francisco",
        "parameterName": "PM2.5",
        "nowcastAQI": 31,
        "aqiCategoryName": "Good",
        "reportingAgency": "Bay Area Air District",
        "lookupBehavior": "Closest Reading By Pollutant",
        "consideredMonitors": "All",
        "lookupBoundary": "50 Miles"
    }
    """

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testBothClientsDecodeStructurallyEquivalentFixturesToIdenticalReadings() async throws {
        MockURLProtocol.requestHandler = { [pollutantFixtureJSON] request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("[\(pollutantFixtureJSON)]".utf8))
        }
        let directClient = AirNowDirectClient(urlSession: MockURLProtocol.makeSession())
        let directReading = try await directClient.fetchCurrentObservations(location: location, apiKey: fakeKey)

        MockURLProtocol.requestHandler = { [pollutantFixtureJSON] request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"observations": [\#(pollutantFixtureJSON)], "cached": false}"#.utf8))
        }
        let serviceClient = BluegullServiceClient(urlSession: MockURLProtocol.makeSession())
        let serviceReading = try await serviceClient.fetchCurrentObservations(location: location)

        XCTAssertEqual(directReading, serviceReading)
    }
}
