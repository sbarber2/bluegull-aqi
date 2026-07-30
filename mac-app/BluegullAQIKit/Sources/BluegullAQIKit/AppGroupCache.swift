import Foundation

/// Cached AQI data for one location, with its own expiry -- written by the
/// container app after a successful fetch, read by the widget's
/// TimelineProvider (bluegull-aqi-10h.7).
public struct AQICacheEntry: Sendable, Equatable, Codable {
    public let reading: AQIReading
    public let fetchedAt: Date
    public let expiresAt: Date

    public init(reading: AQIReading, fetchedAt: Date, expiresAt: Date) {
        self.reading = reading
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

/// Abstraction over the underlying key-value store so `AppGroupCache`'s TTL
/// logic is testable independent of `UserDefaults` specifics.
public protocol SharedCacheStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults(suiteName:)`-backed, for sharing across the container app
/// and widget extension via an App Group.
///
/// `UserDefaults(suiteName:)` itself works even without a real registered
/// App Group entitlement -- confirmed empirically, since it's just a local
/// plist-backed suite until cross-process sharing is actually exercised by
/// two sandboxed processes with a real entitlement. That means this type,
/// unlike `SystemKeychain`/`SystemLocationProvider`/`SystemAddressGeocoder`
/// elsewhere in this package, IS tested directly against the real
/// `UserDefaults` API, not just a fake. What's still unverified is the
/// actual cross-process sharing this exists for -- that needs the real
/// container app and widget extension wired together with a real App Group.
public struct UserDefaultsCacheStore: SharedCacheStore {
    /// Placeholder App Group identifier -- revisit once bluegull-aqi-8ef.5
    /// registers the real one with Apple.
    public static let appGroupIdentifier = "group.org.bluegull.aqi"

    // UserDefaults isn't formally Sendable in the SDK, but Apple documents
    // it as safe to use from multiple threads -- nonisolated(unsafe) states
    // that explicitly rather than silently ignoring the warning.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// nil if `suiteName` couldn't be opened -- deliberately not silently
    /// falling back to `.standard`, since that would mean the container app
    /// and widget silently stop sharing data instead of failing loudly.
    public init?(suiteName: String = appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Location-keyed AQI cache shared between the container app and widget
/// extension via an App Group (bluegull-aqi-10h.7). 1-hour default TTL.
public struct AppGroupCache: Sendable {
    public static let defaultTTL: TimeInterval = 3600

    private let store: SharedCacheStore

    public init(store: SharedCacheStore) {
        self.store = store
    }

    /// nil on a miss -- absent, undecodable, or expired.
    public func get(for location: Location, now: Date = Date()) -> AQIReading? {
        guard let data = store.data(forKey: Self.key(for: location)) else { return nil }
        guard let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data) else { return nil }
        guard !entry.isExpired(now: now) else { return nil }
        return entry.reading
    }

    public func put(_ reading: AQIReading, for location: Location, ttl: TimeInterval = defaultTTL, now: Date = Date()) {
        let entry = AQICacheEntry(reading: reading, fetchedAt: now, expiresAt: now.addingTimeInterval(ttl))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: Self.key(for: location))
    }

    public func remove(for location: Location) {
        store.set(nil, forKey: Self.key(for: location))
    }

    private static func key(for location: Location) -> String {
        "aqi-cache-\(location.latitude)-\(location.longitude)"
    }
}
