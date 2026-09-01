import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.4. The helper process itself can only be verified by
/// observation (bluegull-aqi-hib.9) -- it runs because launchd decided to
/// start it, not because a test did. These cover the part that was
/// deliberately pulled out of it so it *could* be tested: what one wake
/// actually does to the shared cache, and what it does when it can't.
final class HelperRefreshJobTests: XCTestCase {
    private let location = Location(latitude: 37.7749, longitude: -122.4194)

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

    private static func reading(at location: Location) -> AQIReading {
        AQIReading(
            location: location,
            pollutants: [
                PollutantReading(
                    dateObserved: "2026-08-05", hourObserved: "12:00", localTimeZone: "PDT",
                    reportingAreaName: "San Francisco", siteID: "060750005", siteName: "San Francisco",
                    parameterName: "PM2.5", nowcastAQI: 31, aqiCategoryName: "Good",
                    reportingAgency: "Bay Area Air District", lookupBehavior: "Closest Reading By Pollutant",
                    consideredMonitors: "All", lookupBoundary: "50 Miles"
                ),
            ]
        )
    }

    private func makeJob(
        locationResult: FakeLocationProvider.Result,
        cache: AppGroupCache,
        mode: DataSourceMode = .service
    ) -> HelperRefreshJob {
        HelperRefreshJob(
            locationResolver: LocationResolver(
                locationProvider: FakeLocationProvider(result: locationResult),
                geocoder: FakeAddressGeocoder(result: .failure(.noResults)),
                reverseGeocoder: FakeReverseGeocoder(result: .failure(.noResults))
            ),
            coordinator: AQIFetchCoordinator(
                serviceClient: BluegullServiceClient(urlSession: MockURLProtocol.makeSession()),
                apiKeyStore: AirNowAPIKeyStore(keychain: InMemoryKeychain()),
                cache: cache
            ),
            cache: cache,
            currentMode: { mode }
        )
    }

    private func respondWithSampleReading() {
        MockURLProtocol.requestHandler = { [sampleServiceResponseJSON] request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(sampleServiceResponseJSON.utf8))
        }
    }

    // MARK: - The acceptance criterion

    /// The whole point of the epic: with no app running, one wake leaves a
    /// fresh reading in the slot a "Current Location" widget reads directly.
    func testSuccessfulWakeFillsTheCurrentLocationSlot() async {
        respondWithSampleReading()
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        XCTAssertNil(cache.getCurrentLocation(), "precondition: slot starts empty")

        let outcome = await makeJob(locationResult: .success(location), cache: cache).run()

        guard case .refreshed(let reading) = outcome else {
            return XCTFail("Expected .refreshed, got \(outcome)")
        }
        XCTAssertEqual(cache.getCurrentLocation(), reading)
        XCTAssertEqual(cache.currentLocationFreshness(), .fresh)
    }

    /// `AQIFetchCoordinator` writes the coordinate-keyed entry and the
    /// global success timestamp itself -- this asserts the job doesn't have
    /// to duplicate either, since duplicating them is the obvious "fix" if
    /// someone later assumes it does.
    func testSuccessfulWakeAlsoLeavesTheCoordinateKeyedEntryAndSuccessStamp() async {
        respondWithSampleReading()
        let cache = AppGroupCache(store: InMemorySharedCacheStore())

        let outcome = await makeJob(locationResult: .success(location), cache: cache).run()

        guard case .refreshed(let reading) = outcome else {
            return XCTFail("Expected .refreshed, got \(outcome)")
        }
        XCTAssertEqual(cache.get(for: reading.location), reading)
        XCTAssertNotNil(cache.lastSuccessfulFetchDate())
        XCTAssertFalse(cache.isMostRecentFetchAttemptFailing())
    }

    // MARK: - Not spending anything it doesn't have to

    /// The wake interval is deliberately shorter than the soft TTL so grace-
    /// period slop can't leave the slot stale for a whole extra cycle. That
    /// only stays cheap if a wake that finds fresh data does nothing -- no
    /// fetch AND no GPS fix, which is the expensive half.
    func testWakeWithAFreshSlotFetchesNothingAndDoesNotEvenResolveGPS() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("A fresh slot must not trigger a fetch")
            throw AirNowError.requestFailed("unreachable")
        }
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        let cached = Self.reading(at: location)
        cache.putCurrentLocation(cached)

        // A location provider that would fail the test if it were consulted.
        let job = makeJob(locationResult: .failure(.locationUnavailable("must not be asked")), cache: cache)
        let outcome = await job.run()

        XCTAssertEqual(outcome, .skippedStillFresh)
        XCTAssertEqual(cache.getCurrentLocation(), cached, "the fresh entry must be left alone")
    }

    /// Past the soft TTL is exactly when a replacement is wanted
    /// (bluegull-aqi-dc2.5) -- the skip above must not swallow that.
    func testWakeWithASoftExpiredSlotDoesRefresh() async {
        respondWithSampleReading()
        let cache = AppGroupCache(store: InMemorySharedCacheStore())
        // Written an hour and a bit ago: past soft (3600s), inside hard.
        cache.putCurrentLocation(
            Self.reading(at: location),
            now: Date().addingTimeInterval(-3700)
        )
        XCTAssertEqual(cache.currentLocationFreshness(), .stale, "precondition")

        let outcome = await makeJob(locationResult: .success(location), cache: cache).run()

        guard case .refreshed = outcome else {
            return XCTFail("Expected .refreshed, got \(outcome)")
        }
        XCTAssertEqual(cache.currentLocationFreshness(), .fresh)
    }

    // MARK: - Failing without malfunctioning

    /// The normal state before bluegull-aqi-hib.6's first-run flow has run,
    /// and after a user revokes the grant. Must be distinguishable from
    /// every other failure, because it's the only one the app can do
    /// anything about (bluegull-aqi-hib.7).
    func testNoGrantReportsNotAuthorizedAndWritesNothing() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Nothing to fetch for without a location")
            throw AirNowError.requestFailed("unreachable")
        }
        let cache = AppGroupCache(store: InMemorySharedCacheStore())

        let outcome = await makeJob(locationResult: .failure(.permissionDenied), cache: cache).run()

        XCTAssertEqual(outcome, .notAuthorized)
        XCTAssertNil(cache.getCurrentLocation())
        XCTAssertNil(cache.lastFailedFetchDate(), "no fetch was attempted, so none failed")
    }

    /// Authorized but no fix -- including CoreLocation going silent past its
    /// own deadline (bluegull-aqi-10h.22), which is the case a short-lived
    /// helper is most exposed to.
    func testSilentCoreLocationIsReportedAsUnavailableNotAsUnauthorized() async {
        let cache = AppGroupCache(store: InMemorySharedCacheStore())

        let outcome = await makeJob(locationResult: .failure(.timedOut(15)), cache: cache).run()

        XCTAssertEqual(outcome, .locationUnavailable(.timedOut(15)))
    }

    /// A fetch failure has to reach the shared cache's failure timestamp, or
    /// the widget goes on showing a stale number with no hint the source is
    /// broken (bluegull-aqi-e70.39).
    func testFetchFailureIsReportedAndRecordedInTheSharedCache() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }
        let cache = AppGroupCache(store: InMemorySharedCacheStore())

        let outcome = await makeJob(locationResult: .success(location), cache: cache).run()

        guard case .fetchFailed = outcome else {
            return XCTFail("Expected .fetchFailed, got \(outcome)")
        }
        XCTAssertNil(cache.getCurrentLocation())
        XCTAssertTrue(cache.isMostRecentFetchAttemptFailing())
    }

    /// These labels cross a process boundary into the unified log, which is
    /// world-readable -- so they must stay stable AND carry nothing about
    /// where the user is.
    func testOutcomeLabelsAreStableAndCarryNoLocationData() {
        XCTAssertEqual(HelperRefreshJob.Outcome.refreshed(Self.reading(at: location)).label, "refreshed")
        XCTAssertEqual(HelperRefreshJob.Outcome.skippedStillFresh.label, "skipped-still-fresh")
        XCTAssertEqual(HelperRefreshJob.Outcome.notAuthorized.label, "not-authorized")
        XCTAssertEqual(HelperRefreshJob.Outcome.locationUnavailable(.noResults).label, "location-unavailable")
        XCTAssertEqual(HelperRefreshJob.Outcome.fetchFailed(.noAPIKeyConfigured).label, "fetch-failed")

        for label in [
            HelperRefreshJob.Outcome.refreshed(Self.reading(at: location)).label,
            HelperRefreshJob.Outcome.locationUnavailable(.locationUnavailable("at 37.7749, -122.4194")).label,
        ] {
            XCTAssertFalse(label.contains("37.7"), "label leaked a coordinate: \(label)")
            XCTAssertFalse(label.contains("122.4"), "label leaked a coordinate: \(label)")
        }
    }
}
