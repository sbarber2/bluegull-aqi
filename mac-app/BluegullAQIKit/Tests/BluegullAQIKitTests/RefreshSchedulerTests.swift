import XCTest
@testable import BluegullAQIKit

final class RefreshSchedulerTests: XCTestCase {
    func testInstallOffsetIsWithinInterval() {
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let offset = scheduler.installOffset(interval: 3600)
        XCTAssertGreaterThanOrEqual(offset, 0)
        XCTAssertLessThan(offset, 3600)
    }

    func testInstallOffsetIsStableAcrossCalls() {
        // The whole point: re-randomizing on every call would make the
        // refresh interval irregular instead of a consistent per-install
        // cadence.
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let first = scheduler.installOffset()
        let second = scheduler.installOffset()
        let third = scheduler.installOffset()
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    func testInstallOffsetPersistsAcrossSchedulerInstances() {
        // Simulates the container app and widget extension, separate
        // processes both backed by the same shared store, seeing the same
        // schedule.
        let store = InMemorySharedCacheStore()
        let first = RefreshScheduler(store: store).installOffset()
        let second = RefreshScheduler(store: store).installOffset()
        XCTAssertEqual(first, second)
    }

    func testDifferentStoresCanProduceDifferentOffsets() {
        // Not a strict guarantee (two random draws could coincide), but
        // exercises that offset generation isn't hardcoded to a constant.
        let offsets = (0..<20).map { _ in RefreshScheduler(store: InMemorySharedCacheStore()).installOffset() }
        XCTAssertTrue(Set(offsets).count > 1, "expected at least some variation across 20 independent installs")
    }

    func testNextRefreshDateIsExactlyOneIntervalAfterTheLastOne() {
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let interval: TimeInterval = 3600
        let now = Date()

        let first = scheduler.nextRefreshDate(after: now, interval: interval)
        let second = scheduler.nextRefreshDate(after: first, interval: interval)

        XCTAssertEqual(second.timeIntervalSince(first), interval, accuracy: 0.001)
    }

    func testNextRefreshDateIsAlwaysStrictlyAfterNow() {
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let interval: TimeInterval = 3600

        // Try several arbitrary "now" values, including one landing exactly
        // on what would otherwise be a boundary.
        let offset = scheduler.installOffset(interval: interval)
        let epochOnBoundary = Date(timeIntervalSince1970: offset + interval * 5)

        for now in [Date(), Date(timeIntervalSince1970: 0), epochOnBoundary] {
            let next = scheduler.nextRefreshDate(after: now, interval: interval)
            XCTAssertGreaterThan(next, now)
        }
    }

    func testTwoInstallsWithDifferentOffsetsHaveDifferentSchedules() {
        // The actual point of this feature: different installs' refresh
        // times should land at different points within the hour, not all
        // cluster at :00.
        let storeA = InMemorySharedCacheStore()
        let storeB = InMemorySharedCacheStore()
        let schedulerA = RefreshScheduler(store: storeA)
        let schedulerB = RefreshScheduler(store: storeB)

        // Force two different phases directly rather than relying on
        // random draws to differ.
        storeA.set(try! JSONEncoder().encode(600.0), forKey: "refresh-schedule-install-offset")
        storeB.set(try! JSONEncoder().encode(1800.0), forKey: "refresh-schedule-install-offset")

        let now = Date(timeIntervalSince1970: 0)
        let nextA = schedulerA.nextRefreshDate(after: now, interval: 3600)
        let nextB = schedulerB.nextRefreshDate(after: now, interval: 3600)

        XCTAssertNotEqual(nextA, nextB)
        XCTAssertEqual(nextA.timeIntervalSince1970, 600, accuracy: 0.001)
        XCTAssertEqual(nextB.timeIntervalSince1970, 1800, accuracy: 0.001)
    }

    // bluegull-aqi-e70.47

    func testFirstConsecutiveFailureUsesFastRetryInterval() {
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let now = Date()

        let next = scheduler.nextRefreshDate(after: now, consecutiveFailures: 1)

        XCTAssertEqual(next.timeIntervalSince(now), RefreshScheduler.fastRetryInterval, accuracy: 0.001)
    }

    func testConsecutiveFailuresBackOffExponentiallyUpToACap() {
        // 60, 120, 240, then held at the 240s cap -- verified against
        // measured AirNow recovery times (bluegull-aqi-e70.47), not just
        // doubling forever.
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let now = Date()

        let expected: [Int: TimeInterval] = [1: 60, 2: 120, 3: 240, 4: 240, 5: 240, 6: 240]
        for (failures, delay) in expected {
            let next = scheduler.nextRefreshDate(after: now, consecutiveFailures: failures)
            XCTAssertEqual(next.timeIntervalSince(now), delay, accuracy: 0.001, "consecutiveFailures: \(failures)")
        }
    }

    func testZeroConsecutiveFailuresReproducesTheNormalSchedule() {
        // The default -- every pre-existing caller (WidgetTimelineComputer,
        // in particular) has no notion of the container app's own fetch
        // outcome to pass here, so this must be unaffected.
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let now = Date()

        let withoutFailures = scheduler.nextRefreshDate(after: now)
        let explicitZero = scheduler.nextRefreshDate(after: now, consecutiveFailures: 0)

        XCTAssertEqual(withoutFailures, explicitZero)
        XCTAssertNotEqual(withoutFailures.timeIntervalSince(now), RefreshScheduler.fastRetryInterval)
    }

    func testFastRetryCadenceStopsAfterMaxFastRetries() {
        // An outage that outlasts maxFastRetries quick attempts is no
        // longer "transient" -- falls back to the normal hourly schedule
        // rather than hammering a backend that's genuinely down.
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let now = Date()

        let stillFast = scheduler.nextRefreshDate(after: now, consecutiveFailures: RefreshScheduler.maxFastRetries)
        let fallenBack = scheduler.nextRefreshDate(after: now, consecutiveFailures: RefreshScheduler.maxFastRetries + 1)

        XCTAssertEqual(stillFast.timeIntervalSince(now), RefreshScheduler.maxFastRetryInterval, accuracy: 0.001)
        XCTAssertNotEqual(fallenBack.timeIntervalSince(now), RefreshScheduler.maxFastRetryInterval)
    }

    func testFastRetryIntervalIsAlwaysStrictlyAfterNow() {
        let scheduler = RefreshScheduler(store: InMemorySharedCacheStore())
        let now = Date()

        let next = scheduler.nextRefreshDate(after: now, consecutiveFailures: 1)

        XCTAssertGreaterThan(next, now)
    }
}
