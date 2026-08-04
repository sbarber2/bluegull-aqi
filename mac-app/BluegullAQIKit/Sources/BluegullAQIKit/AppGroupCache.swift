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
    /// Every key currently in the store (not just this cache's own entries,
    /// if the store is shared for other purposes) -- used to bound
    /// retention (bluegull-aqi-10h.12): `AppGroupCache` filters to its own
    /// key prefix before acting on the result.
    func allKeys() -> [String]
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
    public static let appGroupIdentifier = "group.solutions.bluegull.aqi"

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

    public func allKeys() -> [String] {
        Array(defaults.dictionaryRepresentation().keys)
    }
}

/// Location-keyed AQI cache shared between the container app and widget
/// extension via an App Group (bluegull-aqi-10h.7). 1-hour default TTL.
///
/// Retention is bounded two ways (bluegull-aqi-10h.12) -- the container app
/// only writes this cache right after a successful fetch, which is also
/// the cheapest, most natural place to sweep it, rather than needing
/// separate scheduled maintenance:
/// 1. Expired entries are deleted, not just skipped -- both reactively (a
///    `get()` that finds an expired entry removes it) and proactively
///    (every `put()` sweeps every entry, not just the one being written).
/// 2. A hard cap on entry count (`maxRetainedEntries`): if still over the
///    cap after sweeping expired entries, the oldest-by-`fetchedAt` entries
///    are evicted until back under it. TTL alone only bounds *age*, not
///    *count* -- someone who used current-location mode while traveling
///    (or resolved many one-off addresses) could otherwise accumulate
///    entries for locations they never revisit, and so never trigger the
///    reactive per-key cleanup that only fires on a `get()` for that
///    specific key.
///
/// File protection: macOS has no per-file Data Protection classes the way
/// iOS does (`NSFileProtectionKey` et al.) -- confirmed against Apple's own
/// Security Guide, which describes Class A on macOS as backed by the
/// FileVault *volume* key rather than a per-file key, and Class D as simply
/// "Not supported in macOS." There's no per-file protection-class API call
/// for this type to make; the actual data-at-rest protection this depends
/// on is FileVault (a system-level, user-controlled setting), not
/// something this package can configure. Bounding what's stored and for
/// how long -- the retention work above -- is the real, actionable
/// mitigation available at this layer.
public struct AppGroupCache: Sendable {
    public static let defaultTTL: TimeInterval = 3600

    /// Deliberately generous relative to the realistic use case (current
    /// location plus a handful of pinned favorites, bluegull-aqi-e70.5) --
    /// a real bound, not effectively unlimited.
    public static let maxRetainedEntries = 10

    private static let keyPrefix = "aqi-cache-"

    /// Deliberately outside `keyPrefix` -- `pruneIfNeeded`/`mostRecentEntry`
    /// only walk keys starting with `keyPrefix` and would otherwise try (and
    /// fail) to decode this as an `AQICacheEntry` and delete it as junk on
    /// the very next `put()`.
    private static let lastSuccessfulFetchKey = "aqi-last-successful-fetch-at"

    /// Also deliberately outside `keyPrefix`, same reasoning as
    /// `lastSuccessfulFetchKey` above -- holds the most recent successful
    /// live-GPS fetch specifically, so a widget configured for "Current
    /// Location" (a nil `SelectLocationIntent.location`, bluegull-aqi-
    /// mtm.20) can look up *that* reading directly instead of falling back
    /// to `mostRecentEntry()`'s "whatever's most recent anywhere," which
    /// was really a pre-per-instance-configuration stopgap (see that
    /// method's own doc comment) and made every "Current Location" widget
    /// mirror whichever location the menu bar happened to fetch last.
    private static let currentLocationKey = "aqi-cache-current-location"

    private let store: SharedCacheStore

    public init(store: SharedCacheStore) {
        self.store = store
    }

    /// nil on a miss -- absent, undecodable, or expired. An expired entry
    /// is deleted here too, not just treated as a miss -- see the type's
    /// doc comment on retention bounding.
    public func get(for location: Location, now: Date = Date()) -> AQIReading? {
        let key = Self.key(for: location)
        guard let data = store.data(forKey: key) else { return nil }
        guard let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data) else {
            store.set(nil, forKey: key)
            return nil
        }
        guard !entry.isExpired(now: now) else {
            store.set(nil, forKey: key)
            return nil
        }
        return entry.reading
    }

    public func put(_ reading: AQIReading, for location: Location, ttl: TimeInterval = defaultTTL, now: Date = Date()) {
        let entry = AQICacheEntry(reading: reading, fetchedAt: now, expiresAt: now.addingTimeInterval(ttl))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: Self.key(for: location))
        pruneIfNeeded(now: now)
    }

    public func remove(for location: Location) {
        store.set(nil, forKey: Self.key(for: location))
    }

    /// Records that a fetch just succeeded, independent of any single
    /// location's own TTL-bounded entry (bluegull-aqi-dc2.1) -- this is the
    /// one piece of "when did we last actually hear from AirNow" that
    /// survives a per-location entry expiring and being swept. Deliberately
    /// just a timestamp, not full `AQIReading` data, so it doesn't reopen
    /// the retention-bounding concerns `AQICacheEntry`'s own doc comment
    /// already addresses.
    public func recordSuccessfulFetch(now: Date = Date()) {
        store.set(try? JSONEncoder().encode(now), forKey: Self.lastSuccessfulFetchKey)
    }

    /// nil if a fetch has never succeeded (fresh install, or the App Group
    /// suite was just cleared) -- distinct from "the most recent fetch's
    /// data has since expired," which still returns a date here even once
    /// `get`/`mostRecentEntry` no longer have anything to show for it.
    public func lastSuccessfulFetchDate() -> Date? {
        guard let data = store.data(forKey: Self.lastSuccessfulFetchKey) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    /// The most recently fetched, still-valid cached reading across every
    /// location -- used by the widget's `TimelineProvider`
    /// (bluegull-aqi-mtm.2) before per-instance location configuration
    /// exists (bluegull-aqi-mtm.3, App Intents). Once that lands, a widget
    /// instance configured for a specific pinned location should prefer
    /// `get(for:)` with that location instead of this.
    ///
    /// Same expired-entry cleanup as `get()` -- deletes what it finds
    /// expired along the way, not just skips it -- for the same retention-
    /// bounding reason (bluegull-aqi-10h.12). nil if nothing is cached, or
    /// everything cached has expired.
    public func mostRecentEntry(now: Date = Date()) -> AQIReading? {
        let myKeys = store.allKeys().filter { $0.hasPrefix(Self.keyPrefix) }
        var newest: AQICacheEntry?

        for key in myKeys {
            guard let data = store.data(forKey: key) else { continue }
            guard let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data) else {
                store.set(nil, forKey: key)
                continue
            }
            guard !entry.isExpired(now: now) else {
                store.set(nil, forKey: key)
                continue
            }
            if newest == nil || entry.fetchedAt > newest!.fetchedAt {
                newest = entry
            }
        }

        return newest?.reading
    }

    /// Records a successful live-GPS fetch under its own stable key
    /// (bluegull-aqi-mtm.20), independent of the coordinate-keyed entry
    /// `AQIFetchCoordinator` already writes via `put(_:for:)` -- GPS
    /// coordinates drift call-to-call, so there's no fixed coordinate key a
    /// "Current Location" reader could look up directly otherwise. Same
    /// TTL/expiry semantics as `put(_:for:)`.
    public func putCurrentLocation(_ reading: AQIReading, ttl: TimeInterval = defaultTTL, now: Date = Date()) {
        let entry = AQICacheEntry(reading: reading, fetchedAt: now, expiresAt: now.addingTimeInterval(ttl))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: Self.currentLocationKey)
    }

    /// nil on a miss -- absent, undecodable, or expired (deleted here too,
    /// same as `get(for:)`). This is the *specific* "what did live GPS
    /// resolve to most recently" answer -- see `currentLocationKey`'s doc
    /// comment for why a widget showing "Current Location" should prefer
    /// this over `mostRecentEntry()`.
    public func getCurrentLocation(now: Date = Date()) -> AQIReading? {
        guard let data = store.data(forKey: Self.currentLocationKey) else { return nil }
        guard let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data) else {
            store.set(nil, forKey: Self.currentLocationKey)
            return nil
        }
        guard !entry.isExpired(now: now) else {
            store.set(nil, forKey: Self.currentLocationKey)
            return nil
        }
        return entry.reading
    }

    private func pruneIfNeeded(now: Date) {
        let myKeys = store.allKeys().filter { $0.hasPrefix(Self.keyPrefix) }
        var live: [(key: String, entry: AQICacheEntry)] = []

        for key in myKeys {
            guard let data = store.data(forKey: key) else { continue }
            guard let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data) else {
                store.set(nil, forKey: key)  // undecodable junk -- drop it
                continue
            }
            if entry.isExpired(now: now) {
                store.set(nil, forKey: key)
            } else {
                live.append((key, entry))
            }
        }

        guard live.count > Self.maxRetainedEntries else { return }
        let oldestFirst = live.sorted { $0.entry.fetchedAt < $1.entry.fetchedAt }
        for stale in oldestFirst.prefix(live.count - Self.maxRetainedEntries) {
            store.set(nil, forKey: stale.key)
        }
    }

    private static func key(for location: Location) -> String {
        "\(keyPrefix)\(location.latitude)-\(location.longitude)"
    }
}
