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
        // bluegull-aqi-dc2.1: a successful fetch also records the
        // TTL-independent marker the stale-cache UI relies on.
        XCTAssertNotNil(cache.lastSuccessfulFetchDate())
    }

    func testServiceModeRateLimitedResponseThrowsServiceModeRateLimited() async {
        // bluegull-aqi-dc2.2: a 429, whether from lambda_handler.py's own
        // cache-miss budget or API Gateway stage throttling rejecting the
        // request before the Lambda even runs (no {"error": ...} body in
        // that case), must not surface as a generic .airNowError.
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"error": "Air quality data temporarily unavailable; please try again shortly"}"#.utf8))
        }

        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )

        do {
            _ = try await coordinator.fetch(location: location, mode: .service)
            XCTFail("Expected .serviceModeRateLimited")
        } catch let error as AQIFetchError {
            XCTAssertEqual(error, .serviceModeRateLimited)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testServiceModeRateLimitWithoutAParseableBodyStillThrowsServiceModeRateLimited() async {
        // The API Gateway stage-throttling case specifically: no JSON body
        // at all, since the request never reached lambda_handler.py.
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("Too Many Requests".utf8))
        }

        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )

        do {
            _ = try await coordinator.fetch(location: location, mode: .service)
            XCTFail("Expected .serviceModeRateLimited")
        } catch let error as AQIFetchError {
            XCTAssertEqual(error, .serviceModeRateLimited)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // bluegull-aqi-e70.39: every failed fetch attempt -- through this one
    // choke point, regardless of caller or mode -- records itself into the
    // shared cache, which is what lets a widget (never fetching for
    // itself when configured to Current Location) know the active source
    // just started failing.
    func testServiceModeFailureRecordsItselfIntoTheSharedCache() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"error": "upstream unavailable"}"#.utf8))
        }

        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: cache
        )

        XCTAssertFalse(cache.isMostRecentFetchAttemptFailing())
        _ = try? await coordinator.fetch(location: location, mode: .service)
        XCTAssertTrue(cache.isMostRecentFetchAttemptFailing())
    }

    func testDirectModeFailureRecordsItselfIntoTheSharedCache() async {
        let keychain = InMemoryKeychain()
        let keyStore = AirNowAPIKeyStore(keychain: keychain)
        try? keyStore.save(fakeKey)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }

        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let coordinator = AQIFetchCoordinator(
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil),
            apiKeyStore: keyStore,
            cache: cache
        )

        _ = try? await coordinator.fetch(location: location, mode: .direct)
        XCTAssertTrue(cache.isMostRecentFetchAttemptFailing())
    }

    // bluegull-aqi-e70.38: a non-429 Service-mode failure gets its own
    // case, not the shared .airNowError -- AirNowError.userMessage's
    // "AirNow"-specific wording doesn't apply to our own backend.
    func testServiceModeFailureWrapsAsServiceModeErrorNotAirNowError() async {
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
            XCTFail("Expected .serviceModeError")
        } catch let error as AQIFetchError {
            guard case .serviceModeError = error else {
                XCTFail("Expected .serviceModeError, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // A body that doesn't parse as lambda_handler.py's own {"error": "..."}
    // contract (e.g. API Gateway's own throttling/gateway-error response,
    // which never reaches the handler) must still produce a real,
    // non-"Unknown error" message -- Steve's own complaint.
    func testServiceModeFailureWithUnparseableBodyStillProducesAGoodMessage() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("<html>Internal Server Error</html>".utf8))
        }

        let coordinator = AQIFetchCoordinator(
            serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
            apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
            cache: AppGroupCache(store: InMemorySharedCacheStore())
        )

        do {
            _ = try await coordinator.fetch(location: location, mode: .service)
            XCTFail("Expected .serviceModeError")
        } catch let error as AQIFetchError {
            XCTAssertFalse(error.userMessage.localizedCaseInsensitiveContains("unknown"))
            XCTAssertTrue(error.userMessage.contains("500"))
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
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil),
            apiKeyStore: keyStore,
            cache: cache
        )

        let reading = try await coordinator.fetch(location: location, mode: .direct)

        XCTAssertEqual(reading.pollutants.first?.nowcastAQI, 31)
        // Fetching writes the cache too -- e70.7's whole point -- not just
        // returns the value to the caller.
        XCTAssertEqual(cache.get(for: location.rounded), reading)
        XCTAssertNotNil(cache.lastSuccessfulFetchDate())
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
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil),
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
            directClient: AirNowDirectClient(urlSession: MockURLProtocol.makeSession(), timeoutDefaults: nil),
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

    func testServiceModeRateLimitedMessageMentionsDirectMode() {
        // bluegull-aqi-dc2.2's actual ask: nudge toward Direct mode, not
        // just say "something went wrong."
        XCTAssertTrue(AQIFetchError.serviceModeRateLimited.userMessage.localizedCaseInsensitiveContains("Direct"))
    }

    // MARK: - serviceModeError (bluegull-aqi-e70.38)

    func testServiceModeErrorMessageMentionsDirectMode() {
        let error = AQIFetchError.serviceModeError(.httpError(statusCode: 500))
        XCTAssertTrue(error.userMessage.localizedCaseInsensitiveContains("Direct"))
    }

    // Steve's own complaint, verbatim: "'Unknown error' usually means
    // something we cannot anticipate, and the service not responding or
    // otherwise telling us it's not available is hardly unexpected."
    func testServiceModeErrorMessageNeverSaysUnknownError() {
        let errors: [AirNowError] = [
            .requestFailed("timed out"),
            .unexpectedResponse,
            .httpError(statusCode: 500),
            .webServiceError(statusCode: 502, message: "No error details in response body"),
            .decodingFailed("truncated"),
        ]
        for error in errors {
            XCTAssertFalse(
                AQIFetchError.serviceModeError(error).userMessage.localizedCaseInsensitiveContains("unknown"),
                "\(error) produced a message that still says \"unknown\""
            )
        }
    }

    // AirNowError.userMessage says "AirNow" when describing what actually
    // went wrong ("Couldn't reach AirNow..."), which is accurate for Direct
    // mode but not for Service mode (talks to our own backend). The generic
    // "switch to Direct mode... for your own AirNow key" nudge legitimately
    // says "AirNow" too -- this only checks that the *failure description*
    // itself doesn't delegate to the misleading AirNow-specific wording.
    func testServiceModeErrorMessageDoesNotDelegateToAirNowSpecificWording() {
        let underlying = AirNowError.requestFailed("timed out")
        let error = AQIFetchError.serviceModeError(underlying)
        XCTAssertFalse(error.userMessage.contains(underlying.userMessage))
    }

    func testServiceModeErrorMessageIncludesTheHTTPStatusWhenKnown() {
        let error = AQIFetchError.serviceModeError(.httpError(statusCode: 503))
        XCTAssertTrue(error.userMessage.contains("503"))
    }
}
