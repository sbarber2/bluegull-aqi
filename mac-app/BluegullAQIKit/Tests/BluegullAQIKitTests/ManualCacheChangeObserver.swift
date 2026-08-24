import BluegullAQIKit
import Foundation

/// Fake `CacheChangeObserving` for tests that want to simulate "the shared
/// cache changed" without a real Darwin notification round-trip
/// (bluegull-aqi-e70.49) -- same reasoning as `InMemorySharedCacheStore`.
/// `simulateChange()` fans out to every subscriber currently iterating a
/// stream from `changes()`, mirroring `CacheChangeBroadcast`'s own "every
/// live subscriber gets every change" semantics.
final class ManualCacheChangeObserver: CacheChangeObserving, @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let lock = NSLock()

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func simulateChange() {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(())
        }
    }
}
