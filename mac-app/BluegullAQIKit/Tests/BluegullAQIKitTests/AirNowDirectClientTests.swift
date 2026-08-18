import XCTest
@testable import BluegullAQIKit

/// All network calls mocked via MockURLProtocol -- no live AirNow traffic in
/// the test suite, matching the Python client's own test approach
/// (bluegull-aqi-10h.3).
final class AirNowDirectClientTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)
    private let fakeKey = "not-a-real-airnow-key-0000000000000000"

    // Mirrors the real AirNow response shape (verified live -- see
    // doc/DESIGN.md and service/tests/test_airnow_client.py's matching
    // Python-side fixture).
    private let sampleResponseJSON = """
    [
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
    ]
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
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        let reading = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)

        // The returned location is rounded (bluegull-aqi-10h.11) -- it's
        // what was actually sent, not the caller's original precise value.
        XCTAssertEqual(reading.location, location.rounded)
        XCTAssertEqual(reading.pollutants.count, 1)
        XCTAssertEqual(reading.pollutants[0].nowcastAQI, 31)
        XCTAssertEqual(reading.pollutants[0].reportingAgency, "Bay Area Air District")
    }

    func testRequestIncludesCorrectQueryParameters() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)
        _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)

        let url = try XCTUnwrap(capturedRequest?.url)
        XCTAssertEqual(url.host, "www.airnowapi.org")
        // Foundation's URL.path strips the trailing slash even though the
        // underlying URL string has one.
        XCTAssertEqual(url.path, "/aq/observation/current/ziplatlong")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        // Rounded to ~1km precision (bluegull-aqi-10h.11), not the
        // caller's original precise 37.7749/-122.4194.
        XCTAssertEqual(queryDict["format"], "application/json")
        XCTAssertEqual(queryDict["latitude"], "37.77")
        XCTAssertEqual(queryDict["longitude"], "-122.42")
        XCTAssertEqual(queryDict["API_KEY"], fakeKey)
    }

    // MARK: - Configurable timeout (bluegull-aqi-e70.43)

    func testRequestUsesTheDefaultTimeoutWhenNoneIsConfigured() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)
        _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.timeoutInterval, RequestTimeoutStore.defaultDirectTimeout)
    }

    func testRequestUsesAConfiguredTimeout() async throws {
        let timeoutDefaults = try XCTUnwrap(UserDefaults(suiteName: "e70.43-direct-timeout-test-\(UUID())"))
        timeoutDefaults.set(25.0, forKey: RequestTimeoutStore.directUserDefaultsKey)

        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            capturedRequest = request
            return self.mockResponse(statusCode: 200, body: sampleResponseJSON, url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: timeoutDefaults)
        _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.timeoutInterval, 25)
    }

    func testWebServiceErrorBodyThrowsEvenWithHTTP200() async throws {
        // bluegull-aqi-10h.19: AirNow returns some errors (e.g. "no
        // observations for this location") with a 200 status.
        let errorJSON = """
        {"WebServiceError": [{"Message": "No observations available for the requested latitude/longitude"}]}
        """
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 200, body: errorJSON, url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        do {
            _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)
            XCTFail("Expected AirNowError.webServiceError")
        } catch AirNowError.webServiceError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 200)
            XCTAssertEqual(message, "No observations available for the requested latitude/longitude")
        }
    }

    func testHTTPErrorWithoutWebServiceErrorBodyThrowsHTTPError() async throws {
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 503, body: "Service Unavailable", url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        do {
            _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)
            XCTFail("Expected AirNowError.httpError")
        } catch AirNowError.httpError(let statusCode) {
            XCTAssertEqual(statusCode, 503)
        }
    }

    func testUnexpectedResponseShapeThrowsDecodingFailed() async throws {
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 200, body: "{\"unexpected\": \"shape\"}", url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        do {
            _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)
            XCTFail("Expected AirNowError.decodingFailed")
        } catch AirNowError.decodingFailed {
            // expected
        }
    }

    func testEmptyArrayIsValidDataNotAnError() async throws {
        // bluegull-aqi-10h.19: an empty array means "no data for this
        // location," a valid (if boring) response, not an error.
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 200, body: "[]", url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        let reading = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)
        XCTAssertEqual(reading.pollutants, [])
    }

    func testAPIKeyNeverAppearsInThrownErrors() async throws {
        MockURLProtocol.requestHandler = { request in
            self.mockResponse(statusCode: 503, body: "Service Unavailable", url: request.url!)
        }
        let client = AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil)

        do {
            _ = try await client.fetchCurrentObservations(location: location, apiKey: fakeKey)
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse("\(error)".contains(fakeKey))
        }
    }
}
