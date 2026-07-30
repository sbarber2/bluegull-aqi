import BluegullAQIKit
import Foundation

/// Fake `SharedCacheStore` for pure TTL/logic tests, independent of
/// `UserDefaults` specifics (bluegull-aqi-10h.7).
final class InMemorySharedCacheStore: SharedCacheStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
    }
}
