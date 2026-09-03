import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.6. The app has no other way to learn whether the helper
/// can do its job -- a location grant belongs to a bundle id, no API lets
/// one process read another bundle's TCC state, and under Option 1 the app
/// holds no grant of its own to consult.
final class LocationHelperStatusStoreTests: XCTestCase {
    /// Nothing recorded is NOT the same as "recorded: no grant". The first
    /// also describes a helper that was never registered, which is a
    /// different thing for the UI to say.
    func testNothingRecordedIsDistinctFromRecordedNotDetermined() {
        let store = InMemorySharedCacheStore()
        let subject = LocationHelperStatusStore(store: store)
        XCTAssertNil(subject.current())

        subject.record(authorization: .notDetermined, lastOutcome: nil)

        XCTAssertEqual(subject.current()?.authorization, .notDetermined)
    }

    func testRoundTripsAuthorizationAndOutcome() {
        let subject = LocationHelperStatusStore(store: InMemorySharedCacheStore())
        let now = Date()

        subject.record(authorization: .authorized, lastOutcome: "refreshed", now: now)

        let state = subject.current()
        XCTAssertEqual(state?.authorization, .authorized)
        XCTAssertEqual(state?.lastOutcome, "refreshed")
        XCTAssertEqual(state?.recordedAt.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A grant revoked in System Settings produces no notification of any
    /// kind, so the next wake overwriting this record is the only way the
    /// app ever finds out.
    func testALaterRecordReplacesAnEarlierOne() {
        let subject = LocationHelperStatusStore(store: InMemorySharedCacheStore())

        subject.record(authorization: .authorized, lastOutcome: "refreshed")
        subject.record(authorization: .refused, lastOutcome: "not-authorized")

        XCTAssertEqual(subject.current()?.authorization, .refused)
        XCTAssertEqual(subject.current()?.lastOutcome, "not-authorized")
    }

    /// The key must sit OUTSIDE `AppGroupCache`'s `aqi-cache-` prefix, which
    /// is swept on every put() -- anything in there that doesn't decode as
    /// an AQICacheEntry is deleted as junk. Sharing a store is the whole
    /// point, so this has to survive its neighbour's housekeeping.
    func testSurvivesAnAppGroupCacheSweep() {
        let store = InMemorySharedCacheStore()
        let subject = LocationHelperStatusStore(store: store)
        let cache = AppGroupCache(store: store)
        subject.record(authorization: .authorized, lastOutcome: "refreshed")

        cache.put(
            AQIReading(location: Location(latitude: 37.7749, longitude: -122.4194), pollutants: []),
            for: Location(latitude: 37.7749, longitude: -122.4194)
        )

        XCTAssertEqual(subject.current()?.authorization, .authorized)
    }

    // MARK: - servicesEnabled (bluegull-aqi-hib.18)

    func testServicesEnabledRoundTrips() {
        let subject = LocationHelperStatusStore(store: InMemorySharedCacheStore())

        subject.record(authorization: .authorized, lastOutcome: "refreshed", servicesEnabled: false)

        XCTAssertEqual(subject.current()?.servicesEnabled, false)
    }

    /// THE IMPORTANT ONE, and it deliberately does not round-trip through
    /// the current type -- doing that would prove nothing, because both
    /// ends would share whatever shape the type happens to have today.
    ///
    /// This decodes a LITERAL record in the pre-hib.18 format, which is what
    /// is actually sitting in the App Group of every existing install. Had
    /// `servicesEnabled` been added as non-optional, decoding would fail
    /// outright, `current()` would return nil, and `derive` would report
    /// `.neverSetUp` -- telling every upgrading user their helper was never
    /// set up, while it ran perfectly. Silent, total, and invisible to any
    /// test that encodes with the same version it decodes with.
    func testARecordWrittenBeforeServicesEnabledExistedStillDecodes() throws {
        let store = InMemorySharedCacheStore()
        let legacy = #"{"authorization":"authorized","lastOutcome":"refreshed","recordedAt":810042777.135433}"#
        store.set(Data(legacy.utf8), forKey: "location-helper-state")
        let subject = LocationHelperStatusStore(store: store)

        let state = try XCTUnwrap(subject.current(), "a pre-hib.18 record must still decode")

        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(state.lastOutcome, "refreshed")
        XCTAssertNil(state.servicesEnabled, "absent must mean unknown, never false")
    }

    /// And the consequence of the above, end to end: an upgrading install
    /// whose record predates the field must still be reported as working,
    /// not diagnosed with a problem it does not have.
    func testALegacyRecordStillDerivesAsWorking() {
        let store = InMemorySharedCacheStore()
        let legacy = #"{"authorization":"authorized","lastOutcome":"refreshed","recordedAt":\#(Date().timeIntervalSinceReferenceDate)}"#
        store.set(Data(legacy.utf8), forKey: "location-helper-state")
        let subject = LocationHelperStatusStore(store: store)
        subject.recordAvailability(.enabled)

        XCTAssertEqual(subject.backgroundRefreshStatus(), .working)
    }

    /// These strings are persisted across processes and across app updates,
    /// so they are a wire format, not an implementation detail.
    func testRawValuesAreStable() {
        XCTAssertEqual(LocationHelperAuthorization.notDetermined.rawValue, "notDetermined")
        XCTAssertEqual(LocationHelperAuthorization.refused.rawValue, "refused")
        XCTAssertEqual(LocationHelperAuthorization.authorized.rawValue, "authorized")
    }
}
