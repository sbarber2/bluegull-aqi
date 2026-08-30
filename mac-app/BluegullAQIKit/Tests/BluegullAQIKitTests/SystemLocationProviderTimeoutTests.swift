import CoreLocation
import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-10h.22. The bug these cover is silence, not failure:
/// `requestLocation()` returning without CoreLocation ever calling back.
/// Before the fix that suspended the caller permanently, and no test could
/// see it because `SystemLocationProvider` talked to a real
/// `CLLocationManager` -- hence `LocationManaging` and the fake below.
final class SystemLocationProviderTimeoutTests: XCTestCase {
    /// Delegate callbacks are typed to take a `CLLocationManager`, so a
    /// throwaway one is needed just to fill the argument. Constructing it
    /// touches no authorization and starts nothing.
    private let unusedManager = CLLocationManager()

    // MARK: - The actual regression

    func testTimesOutWhenCoreLocationNeverCallsBack() async {
        let manager = FakeLocationManager()  // requestLocation() does nothing at all
        let provider = SystemLocationProvider(manager: manager, timeout: 0.05)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.timedOut")
        } catch LocationResolverError.timedOut(let elapsed) {
            XCTAssertEqual(elapsed, 0.05, accuracy: 0.0001)
        } catch {
            XCTFail("Expected .timedOut, got \(error)")
        }
    }

    /// The point of the timeout isn't only to unblock the caller -- a
    /// pending request left running would keep the process busy, which is
    /// the whole reason this matters for a short-lived helper.
    func testTimeoutCancelsThePendingRequest() async {
        let manager = FakeLocationManager()
        let stopped = expectation(description: "stopUpdatingLocation called")
        manager.onStopUpdatingLocation = { stopped.fulfill() }
        let provider = SystemLocationProvider(manager: manager, timeout: 0.05)

        _ = try? await provider.currentLocation()

        await fulfillment(of: [stopped], timeout: 2)
    }

    /// An empty `locations` array is ignored by the delegate (another
    /// callback may follow), which before the fix was a second silent path
    /// to a permanent hang.
    func testEmptyLocationsUpdateStillEventuallyTimesOut() async {
        let manager = FakeLocationManager()
        manager.onRequestLocation = { [unusedManager] delegate in
            delegate?.locationManager?(unusedManager, didUpdateLocations: [])
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 0.05)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.timedOut")
        } catch LocationResolverError.timedOut {
            // expected
        } catch {
            XCTFail("Expected .timedOut, got \(error)")
        }
    }

    // MARK: - The timeout must not break the paths that already worked

    func testFixArrivingBeforeTheDeadlineWins() async throws {
        let manager = FakeLocationManager()
        manager.onRequestLocation = { [unusedManager] delegate in
            delegate?.locationManager?(
                unusedManager,
                didUpdateLocations: [CLLocation(latitude: 37.7749, longitude: -122.4194)]
            )
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 30)

        let location = try await provider.currentLocation()

        XCTAssertEqual(location.latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(location.longitude, -122.4194, accuracy: 0.0001)
        XCTAssertFalse(manager.didStopUpdatingLocation, "A completed request shouldn't be cancelled")
    }

    func testReportedFailureBeatsTheDeadlineAndStaysDistinctFromIt() async {
        let manager = FakeLocationManager()
        manager.onRequestLocation = { [unusedManager] delegate in
            delegate?.locationManager?(
                unusedManager,
                didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.network.rawValue)
            )
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 30)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.locationUnavailable")
        } catch LocationResolverError.locationUnavailable {
            // CoreLocation said no -- must NOT be reported as silence.
        } catch {
            XCTFail("Expected .locationUnavailable, got \(error)")
        }
    }

    /// Resuming a `CheckedContinuation` twice traps, so a fix landing just
    /// after the deadline has to lose quietly rather than crash the app.
    func testLateFixAfterTimeoutIsDiscardedRatherThanResumingTwice() async {
        let manager = FakeLocationManager()
        let provider = SystemLocationProvider(manager: manager, timeout: 0.05)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.timedOut")
        } catch LocationResolverError.timedOut {
            // expected
        } catch {
            XCTFail("Expected .timedOut, got \(error)")
        }

        // The delegate is still wired up, exactly as a real late CoreLocation
        // callback would find it. This trapping would fail the test process.
        manager.delegate?.locationManager?(
            unusedManager,
            didUpdateLocations: [CLLocation(latitude: 37.7749, longitude: -122.4194)]
        )
        manager.delegate?.locationManager?(
            unusedManager,
            didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.network.rawValue)
        )
    }

    func testUnauthorizedStillFailsFastWithoutWaitingOutTheDeadline() async {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .denied
        let provider = SystemLocationProvider(manager: manager, timeout: 30)

        let start = Date()
        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.permissionDenied")
        } catch LocationResolverError.permissionDenied {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
            XCTAssertFalse(manager.didRequestLocation)
        } catch {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }
}

/// Stands in for `CLLocationManager`. Its default behaviour is the one that
/// used to hang: `requestLocation()` accepts the call and never says
/// anything again.
private final class FakeLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    weak var delegate: CLLocationManagerDelegate?

    var onRequestLocation: ((CLLocationManagerDelegate?) -> Void)?
    var onStopUpdatingLocation: (() -> Void)?

    private(set) var didRequestLocation = false
    private(set) var didStopUpdatingLocation = false

    func requestLocation() {
        didRequestLocation = true
        onRequestLocation?(delegate)
    }

    func stopUpdatingLocation() {
        didStopUpdatingLocation = true
        onStopUpdatingLocation?()
    }
}
