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

    // MARK: - bluegull-aqi-hib.4: the authorization-status race

    /// The bug: `CLLocationManager` populates `authorizationStatus`
    /// asynchronously, so it reads `.notDetermined` for the first moments
    /// after construction whatever the real grant is. Reading it
    /// synchronously told a fully-authorized process it had no permission.
    /// A long-lived app never notices -- its manager settled minutes ago --
    /// but a launchd-woken helper constructs its manager and asks in the
    /// same breath, which is the entire bluegull-aqi-hib design.
    func testStatusThatIsMerelyUnpopulatedIsWaitedOutRatherThanTreatedAsDenial() async throws {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .notDetermined
        // Assigning the delegate is what makes a real manager report -- so
        // that is where the fake flips to the truth, as CoreLocation would.
        manager.onDelegateSet = { [unusedManager] delegate in
            manager.authorizationStatus = .authorizedAlways
            delegate?.locationManagerDidChangeAuthorization?(unusedManager)
        }
        manager.onRequestLocation = { [unusedManager] delegate in
            delegate?.locationManager?(
                unusedManager,
                didUpdateLocations: [CLLocation(latitude: 37.7749, longitude: -122.4194)]
            )
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 30)

        let location = try await provider.currentLocation()

        XCTAssertEqual(location.latitude, 37.7749, accuracy: 0.0001)
    }

    /// The same wait must not turn a real denial into a fix -- if the
    /// settled answer is "no", it stays "no".
    func testStatusThatSettlesToDeniedStillFails() async {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .notDetermined
        manager.onDelegateSet = { [unusedManager] delegate in
            manager.authorizationStatus = .denied
            delegate?.locationManagerDidChangeAuthorization?(unusedManager)
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 30)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.permissionDenied")
        } catch LocationResolverError.permissionDenied {
            XCTAssertFalse(manager.didRequestLocation)
        } catch {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    /// A genuinely undetermined process -- no grant yet, the normal state
    /// before bluegull-aqi-hib.6's first-run flow -- must fail on the FIRST
    /// callback, not burn the whole settle deadline. Every wake pays this
    /// cost otherwise.
    func testGenuinelyUndeterminedFailsOnTheFirstCallbackNotTheDeadline() async {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .notDetermined
        manager.onDelegateSet = { [unusedManager] delegate in
            delegate?.locationManagerDidChangeAuthorization?(unusedManager)
        }
        let provider = SystemLocationProvider(manager: manager, timeout: 30, authorizationSettleTimeout: 30)

        let start = Date()
        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.permissionDenied")
        } catch LocationResolverError.permissionDenied {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, "waited out the deadline instead of trusting the callback")
        } catch {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    /// A manager that never calls back at all must not suspend the caller
    /// forever -- the same silence-not-failure defect as
    /// bluegull-aqi-10h.22, one layer up.
    func testNoAuthorizationCallbackAtAllGivesUpOnTheDeadline() async {
        let manager = FakeLocationManager()  // onDelegateSet nil: never reports
        manager.authorizationStatus = .notDetermined
        let provider = SystemLocationProvider(manager: manager, timeout: 30, authorizationSettleTimeout: 0.05)

        do {
            _ = try await provider.currentLocation()
            XCTFail("Expected LocationResolverError.permissionDenied")
        } catch LocationResolverError.permissionDenied {
            XCTAssertFalse(manager.didRequestLocation)
        } catch {
            XCTFail("Expected .permissionDenied, got \(error)")
        }
    }

    /// An already-decided status must not pay for the wait at all -- this is
    /// the path every refresh in the long-running app takes.
    func testAlreadyDecidedStatusIsNotWaitedOn() async throws {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .authorizedAlways
        manager.onRequestLocation = { [unusedManager] delegate in
            delegate?.locationManager?(
                unusedManager,
                didUpdateLocations: [CLLocation(latitude: 37.7749, longitude: -122.4194)]
            )
        }
        // A settle deadline long enough that waiting on it would hang the
        // test rather than merely slow it down.
        let provider = SystemLocationProvider(manager: manager, timeout: 30, authorizationSettleTimeout: 600)

        _ = try await provider.currentLocation()

        // Exactly one: the in-flight request's own delegate. A settle pass
        // would have installed its watch first, making two -- which is what
        // the .notDetermined tests above assert instead.
        XCTAssertEqual(manager.delegateAssignmentCount, 1)
    }
}

/// Stands in for `CLLocationManager`. Its default behaviour is the one that
/// used to hang: `requestLocation()` accepts the call and never says
/// anything again.
private final class FakeLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways

    /// Assignment has a side effect on a real `CLLocationManager` -- it is
    /// what provokes the first `locationManagerDidChangeAuthorization` --
    /// so the fake models that rather than pretending it is a plain
    /// property (bluegull-aqi-hib.4).
    weak var delegate: CLLocationManagerDelegate? {
        didSet {
            delegateAssignmentCount += 1
            onDelegateSet?(delegate)
        }
    }

    private(set) var delegateAssignmentCount = 0

    var onDelegateSet: ((CLLocationManagerDelegate?) -> Void)?
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
