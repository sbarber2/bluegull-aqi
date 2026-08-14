import XCTest
@testable import BluegullAQIKit

/// Mirrors AirNowDirectClientTests's approach -- MockURLProtocol, no live
/// traffic against the deployed dev backend. The one structural difference
/// under test: the wire shape is `{"observations": [...], "cached": bool}`,
/// not a bare array, and error bodies are `{"error": "..."}`, not AirNow's
/// own `{"WebServiceError": [...]}` shape (bluegull-aqi-10h.4).
final class BluegullServiceClientTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)

    private let sampleResponseJSON = """
    {
        "observations": [
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
        ],
        "cached": true
    }
    """

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func mockResponse(statusCode: Int, body: String, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, Data(body.utf8))
    }

    func testFetchCurrentObservationsSuccess() async throws {
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: nil)

        let reading = try await client.fetchCurrentObservations(location: location)

        // Same rounding contract as AirNowDirectClient (bluegull-aqi-10h.11).
        XCTAssertEqual(reading.location, location.rounded)
        XCTAssertEqual(reading.pollutants.count, 1)
        XCTAssertEqual(reading.pollutants[0].nowcastAQI, 31)
        XCTAssertEqual(reading.pollutants[0].reportingAgency, "Bay Area Air District")
    }

    func testRequestIncludesCorrectQueryParametersAndNoAPIKey() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: nil)
        _ = try await client.fetchCurrentObservations(location: location)

        let url = try XCTUnwrap(capturedRequest?.url)
        XCTAssertEqual(url.host, "dev.aqi.bluegull.solutions")
        XCTAssertEqual(url.path, "/aqi")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        // Rounded to ~1km precision (bluegull-aqi-10h.11).
        XCTAssertEqual(queryDict["lat"], "37.77")
        XCTAssertEqual(queryDict["lon"], "-122.42")
        // No API_KEY parameter -- unlike AirNowDirectClient, the backend
        // holds its own key server-side. That's the whole point of Service
        // mode.
        XCTAssertNil(queryDict["API_KEY"])
    }

    func testErrorBodyThrowsWebServiceErrorWithMessage() async throws {
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: nil)
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 502, body: #"{"error": "upstream unavailable"}"#, url: request.url!)
        }

        do {
            _ = try await client.fetchCurrentObservations(location: location)
            XCTFail("Expected AirNowError.webServiceError")
        } catch AirNowError.webServiceError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 502)
            XCTAssertEqual(message, "upstream unavailable")
        }
    }

    func testErrorResponseWithoutParseableBodyStillThrowsWebServiceError() async throws {
        // lambda_handler.py always returns {"error": "..."} on failure, but
        // the client shouldn't crash even if that contract were ever
        // violated (e.g. an API Gateway-generated 5xx bypassing the
        // handler entirely).
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: nil)
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 503, body: "Service Unavailable", url: request.url!)
        }

        do {
            _ = try await client.fetchCurrentObservations(location: location)
            XCTFail("Expected AirNowError.webServiceError")
        } catch AirNowError.webServiceError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(message, "Unknown error")
        }
    }

    func testUnexpectedResponseShapeThrowsDecodingFailed() async throws {
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: nil)
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 200, body: "{\"unexpected\": \"shape\"}", url: request.url!)
        }

        do {
            _ = try await client.fetchCurrentObservations(location: location)
            XCTFail("Expected AirNowError.decodingFailed")
        } catch AirNowError.decodingFailed {
            // expected
        }
    }

    // bluegull-aqi-e70.28: the hidden dev override, when set, redirects
    // requests instead of the hardcoded dev stack.
    func testDevOverrideRedirectsRequestToOverriddenHost() async throws {
        let overrideDefaults = try XCTUnwrap(UserDefaults(suiteName: "e70.28-override-test-\(UUID())"))
        overrideDefaults.set("https://localhost:9999/aqi", forKey: DevServiceURLOverrideStore.userDefaultsKey)

        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: overrideDefaults)
        _ = try await client.fetchCurrentObservations(location: location)

        let url = try XCTUnwrap(capturedRequest?.url)
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 9999)
        XCTAssertEqual(url.path, "/aqi")
    }

    // No override key ever written -- same as production's real App Group
    // suite before Steve has ever touched the hidden field.
    func testNoDevOverrideStoredFallsBackToDefaultHost() async throws {
        let overrideDefaults = try XCTUnwrap(UserDefaults(suiteName: "e70.28-no-override-test-\(UUID())"))

        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = BluegullServiceClient(urlSession: MockURLProtocol.makeSession(), overrideDefaults: overrideDefaults)
        _ = try await client.fetchCurrentObservations(location: location)

        let url = try XCTUnwrap(capturedRequest?.url)
        XCTAssertEqual(url.host, "dev.aqi.bluegull.solutions")
    }
}
