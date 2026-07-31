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

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testServiceModeThrowsNotYetAvailable() async {
        let coordinator = makeCoordinator(keychain: InMemoryKeychain())

        do {
            _ = try await coordinator.fetch(location: location, mode: .service)
            XCTFail("Expected .serviceModeNotYetAvailable")
        } catch let error as AQIFetchError {
            XCTAssertEqual(error, .serviceModeNotYetAvailable)
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
