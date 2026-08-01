import XCTest
@testable import BluegullAQIKit

final class AQIFetchCoordinatorTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)
    private let fakeKey = "not-a-real-airnow-key-0000000000000000"

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

    private let sampleServiceResponseJSON = """
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
        "cached": false
    }
    """

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testServiceModeFetchesAndCaches() async throws {
        MockURLProtocol.requestHandler = { [sampleServiceResponseJSON] request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(sampleServiceResponseJSON.utf8))
        }

        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: cache
        )

        let reading = try await coordinator.fetch(location: location, mode: .service)

        XCTAssertEqual(reading.pollutants.first?.nowcastAQI, 31)
        XCTAssertEqual(cache.get(for: location.rounded), reading)
    }

    func testServiceModeFailureWrapsAsAirNowError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"error": "upstream unavailable"}"#.utf8))
        }

        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )

        do {
            _ = try await coordinator.fetch(location: location, mode: .service)
            XCTFail("Expected .airNowError")
        } catch let error as AQIFetchError {
            guard case .airNowError = error else {
                XCTFail("Expected .airNowError, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDirectModeWithNoSavedKeyThrowsNoAPIKeyConfigured() async {
        let coordinator = makeCoordinator(keychain: InMemoryKeychain())

        do {
            _ = try await coordinator.fetch(location: location, mode: .direct)
            XCTFail("Expected .noAPIKeyConfigured")
        } catch let error as AQIFetchError {
            XCTAssertEqual(error, .noAPIKeyConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDirectModeWithSavedKeyFetchesAndCaches() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = AirNowAPIKeyStore(keychain: keychain)
        try keyStore.save(fakeKey)

        MockURLProtocol.requestHandler = { [sampleResponseJSON] request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(sampleResponseJSON.utf8))
        }

        let cacheStore = InMemorySharedCacheStore()
        let cache = AppGroupCache(store: cacheStore)
        let coordinator = AQIFetchCoordinator(
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: keyStore,
            cache: cache
        )

        let reading = try await coordinator.fetch(location: location, mode: .direct)

        XCTAssertEqual(reading.pollutants.first?.nowcastAQI, 31)
        // Fetching writes the cache too -- e70.7's whole point -- not just
        // returns the value to the caller.
        XCTAssertEqual(cache.get(for: location.rounded), reading)
    }

    func testDirectModeAirNowFailureWrapsAsAirNowError() async {
        let keychain = InMemoryKeychain()
        let keyStore = AirNowAPIKeyStore(keychain: keychain)
        try? keyStore.save(fakeKey)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }

        let coordinator = AQIFetchCoordinator(
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: keyStore,
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )

        do {
            _ = try await coordinator.fetch(location: location, mode: .direct)
            XCTFail("Expected .airNowError")
        } catch let error as AQIFetchError {
            guard case .airNowError = error else {
                XCTFail("Expected .airNowError, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func makeCoordinator(keychain: KeychainStore) -> AQIFetchCoordinator {
        AQIFetchCoordinator(
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: keychain),
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )
    }
}

/// bluegull-aqi-e70.24: every case needs real, non-empty user-facing text
/// -- found genuinely missing before this, which is exactly why switching
/// to Service mode looked like the app had silently broken instead of
/// clearly saying "this mode isn't ready yet."
final class UserMessageTests: XCTestCase {
    func testAQIFetchErrorMessagesAreNonEmptyAndDistinct() {
        XCTAssertFalse(AQIFetchError.noAPIKeyConfigured.userMessage.isEmpty)
        let wrapped = AQIFetchError.airNowError(.webServiceError(statusCode: 401, message: "Invalid API key"))
        XCTAssertNotEqual(AQIFetchError.noAPIKeyConfigured.userMessage, wrapped.userMessage)
    }

    func testAirNowErrorWebServiceErrorMessagePassesThroughVerbatim() {
        let error = AirNowError.webServiceError(statusCode: 401, message: "Invalid API key")
        XCTAssertEqual(error.userMessage, "Invalid API key")
    }

    func testAirNowErrorMessagesAreNonEmpty() {
        let errors: [AirNowError] = [
            .requestFailed("timed out"),
            .unexpectedResponse,
            .httpError(statusCode: 500),
            .webServiceError(statusCode: 400, message: "bad request"),
            .decodingFailed("truncated"),
        ]
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    func testAQIFetchErrorAirNowCaseDelegatesToTheWrappedError() {
        let inner = AirNowError.webServiceError(statusCode: 401, message: "Invalid API key")
        XCTAssertEqual(AQIFetchError.airNowError(inner).userMessage, inner.userMessage)
    }
}
