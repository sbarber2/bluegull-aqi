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
}
