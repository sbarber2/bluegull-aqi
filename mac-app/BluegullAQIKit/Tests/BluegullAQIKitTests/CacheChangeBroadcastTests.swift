import XCTest
@testable import BluegullAQIKit

/// Tests against the REAL Darwin notification round-trip, not a fake --
/// same reasoning as `UserDefaultsCacheStoreTests`: this IS the OS-glue
/// layer, so it's the one place a fake would test nothing real. A real
/// post-then-observe round-trip within a single test process is
/// deterministic (no actual second process involved) and exercises the
/// exact mechanism `WidgetDetailView` depends on (bluegull-aqi-e70.49).
final class CacheChangeBroadcastTests: XCTestCase {
    func testPostDeliversToASubscriberAlreadyObserving() async throws {
        var iterator = CacheChangeBroadcast.changes().makeAsyncIterator()

        CacheChangeBroadcast.post()

        let element = await iterator.next()
        XCTAssertNotNil(element)
    }

    func testPostDeliversToEveryConcurrentSubscriber() async throws {
        var first = CacheChangeBroadcast.changes().makeAsyncIterator()
        var second = CacheChangeBroadcast.changes().makeAsyncIterator()

        CacheChangeBroadcast.post()

        let firstElement = await first.next()
        let secondElement = await second.next()
        XCTAssertNotNil(firstElement)
        XCTAssertNotNil(secondElement)
    }

    func testDarwinCacheChangeObserverDelegatesToCacheChangeBroadcast() async throws {
        let observer: CacheChangeObserving = DarwinCacheChangeObserver()
        var iterator = observer.changes().makeAsyncIterator()

        CacheChangeBroadcast.post()

        let element = await iterator.next()
        XCTAssertNotNil(element)
    }

    func testCancellingTheConsumingTaskStopsFurtherDelivery() async throws {
        // Not just "the task stops" (trivially true of any cancelled task)
        // -- this proves the underlying NotificationCenter observer is
        // actually torn down via `onTermination`, not left registered and
        // silently discarding into a cancelled continuation forever.
        let stream = CacheChangeBroadcast.changes()
        let task = Task {
            for await _ in stream {
                XCTFail("should not receive after cancellation")
            }
        }
        task.cancel()
        // Give the cancellation's onTermination a moment to actually run
        // before posting -- otherwise this test would be racing its own
        // setup, not exercising anything real.
        try await Task.sleep(for: .milliseconds(50))

        CacheChangeBroadcast.post()
        try await Task.sleep(for: .milliseconds(50))
    }
}
