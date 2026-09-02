import CoreLocation
import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.13. This hazard was fixed three times, independently,
/// and every one of those fixes came after the bug had already shipped and
/// been found in the field -- because only one of the three sites was
/// reachable from a test target at all. These are the tests that could not
/// previously be written.
final class LocationAuthorizationWatcherTests: XCTestCase {
    /// Delegate callbacks are typed to take a `CLLocationManager`, so a
    /// throwaway one fills the argument. Constructing it touches no
    /// authorization and starts nothing.
    private let unusedManager = CLLocationManager()

    // MARK: - The distinction that was asserted nowhere

    /// OBSERVING: the first callback IS the answer, and `.notDetermined` is
    /// a perfectly real answer -- a helper whose first run hasn't happened
    /// genuinely has no grant. Resolving here is what stops the caller
    /// waiting out a deadline for a question already answered.
    func testAnObserverResolvesOnANotDeterminedCallback() async {
        let watcher = LocationAuthorizationWatcher(timeout: 30, resolvesOnNotDetermined: true)
        let manager = FakeAuthorizationReporter(status: .notDetermined)
        watcher.install(on: manager)

        let task = Task { await watcher.settledStatus(fallingBackTo: { .authorizedAlways }) }
        watcher.report(.notDetermined)

        let settled = await task.value
        XCTAssertEqual(settled, .notDetermined)
    }

    /// ASKING: the same callback means the opposite. CoreLocation fires it
    /// on delegate assignment, before the user has touched the dialog, so
    /// resolving on it would report "no grant" the instant we asked --
    /// turning every first run into an immediate false refusal.
    func testAnAskerIgnoresTheSameCallbackAndWaitsForARealAnswer() async {
        let watcher = LocationAuthorizationWatcher(timeout: 30, resolvesOnNotDetermined: false)
        let manager = FakeAuthorizationReporter(status: .notDetermined)
        watcher.install(on: manager)

        let task = Task { await watcher.settledStatus(fallingBackTo: { .denied }) }
        watcher.report(.notDetermined)   // the prompt appearing, not an answer
        watcher.report(.authorizedAlways)  // the user actually answering

        let settled = await task.value
        XCTAssertEqual(settled, .authorizedAlways, "the real answer must win, not the prompt-appeared callback")
    }

    // MARK: - Resolve exactly once, whatever the order

    /// The callback can land before anyone is waiting -- `install(on:)`
    /// provokes it synchronously on a real manager. Recording the answer
    /// regardless is what makes that safe.
    func testACallbackBeforeAnyoneWaitsIsNotLost() async {
        let watcher = LocationAuthorizationWatcher(timeout: 30)

        watcher.report(.authorizedAlways)
        let settled = await watcher.settledStatus(fallingBackTo: { .denied })

        XCTAssertEqual(settled, .authorizedAlways)
    }

    /// The whole reason this type exists: a manager that never answers must
    /// not suspend the caller forever. The fallback is read only here, so a
    /// caller still gets the best value available rather than a guess.
    func testSilenceFallsBackRatherThanHanging() async {
        let watcher = LocationAuthorizationWatcher(timeout: 0.05)

        let settled = await watcher.settledStatus(fallingBackTo: { .authorizedAlways })

        XCTAssertEqual(settled, .authorizedAlways)
    }

    /// A late callback arriving after the deadline must lose quietly --
    /// resuming a `CheckedContinuation` twice traps, which would take the
    /// whole process down.
    func testALateCallbackAfterTheDeadlineIsDiscarded() async {
        let watcher = LocationAuthorizationWatcher(timeout: 0.05)
        _ = await watcher.settledStatus(fallingBackTo: { .denied })

        // Would trap if it double-resumed.
        watcher.report(.authorizedAlways)
        watcher.report(.notDetermined)
    }

    /// `install(on:)` is what provokes the first callback, so it has to
    /// actually take the delegate slot.
    func testInstallingTakesTheDelegateSlot() {
        let watcher = LocationAuthorizationWatcher()
        let manager = FakeAuthorizationReporter(status: .denied)

        watcher.install(on: manager)

        XCTAssertTrue(manager.delegate === watcher)
    }
}

private final class FakeAuthorizationReporter: LocationAuthorizationReporting {
    var authorizationStatus: CLAuthorizationStatus
    weak var delegate: CLLocationManagerDelegate?

    init(status: CLAuthorizationStatus) {
        authorizationStatus = status
    }
}
