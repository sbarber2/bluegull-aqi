import Foundation

/// How usable a cached entry still is (bluegull-aqi-dc2.5).
public enum AQIFreshness: Sendable, Equatable {
    /// Within the soft TTL -- display it, don't refetch on its account.
    case fresh
    /// Past the soft TTL but within the hard one -- still worth displaying
    /// (clearly aged), and worth refetching to replace.
    case stale
    /// Past the hard TTL -- too old to show at all.
    case expired
}

/// Cached AQI data for one location, with two expiry thresholds -- written
/// after a successful fetch by whichever process made it (bluegull-aqi-10h.7,
/// and either process since bluegull-aqi-mtm.24), read by the widget's
/// TimelineProvider and the menu bar alike.
///
/// Two thresholds rather than one (bluegull-aqi-dc2.5, stale-while-
/// revalidate): with a single TTL, the instant an entry expired the surface
/// had nothing to show and rendered "Data Unavailable" while a refetch ran
/// -- measured at 2.826s for a real backend cache miss, during which a
/// perfectly serviceable hour-old reading was sitting right there unused.
/// Now an entry stays displayable well past the point where it stops being
/// considered current.
public struct AQICacheEntry: Sendable, Equatable, Codable {
    public let reading: AQIReading
    public let fetchedAt: Date
    public let softExpiresAt: Date
    public let hardExpiresAt: Date

    public init(reading: AQIReading, fetchedAt: Date, softExpiresAt: Date, hardExpiresAt: Date) {
        self.reading = reading
        self.fetchedAt = fetchedAt
        self.softExpiresAt = softExpiresAt
        self.hardExpiresAt = hardExpiresAt
    }

    public func freshness(at now: Date = Date()) -> AQIFreshness {
        if now < softExpiresAt { return .fresh }
        if now < hardExpiresAt { return .stale }
        return .expired
    }

    /// Past the *hard* threshold -- i.e. no longer displayable at all.
    /// Deliberately not "past soft": a soft-expired entry is still shown.
    public func isExpired(now: Date = Date()) -> Bool {
        freshness(at: now) == .expired
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
        // bluegull-aqi-e70.49: the one real write path both the container
        // app and the widget extension go through (they're separate
        // processes, each with their own `UserDefaultsCacheStore` instance
        // over the same App Group suite) -- posting here, not scattered
        // across `AppGroupCache`'s individual methods, means every write
        // broadcasts regardless of which higher-level call produced it, and
        // `InMemorySharedCacheStore` (every test's fake) stays untouched.
        CacheChangeBroadcast.post()
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
    /// Matches AirNow's own hourly update cadence -- refetching more often
    /// than the source data changes buys nothing. Deliberately NOT the
    /// design doc's suggested 10 minutes: this API is rate-limited, and 10
    /// minutes would multiply request volume roughly 6x for no fresher data.
    public static let defaultSoftTTL: TimeInterval = 3600
    /// The fallback window past soft expiry -- an entry is still shown,
    /// visibly aged, rather than immediately going to "Data Unavailable"
    /// while a refetch is attempted (bluegull-aqi-dc2.5).
    public static let defaultHardTTL: TimeInterval = 3 * 3600

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

    /// Also deliberately outside `keyPrefix`, same reasoning as
    /// `lastSuccessfulFetchKey` above -- the global counterpart
    /// (bluegull-aqi-e70.39) to it: "when did a fetch attempt, by either
    /// process, last fail" rather than "when did one last succeed."
    /// Together the two let `isMostRecentFetchAttemptFailing` answer "is the
    /// active data source currently broken" without any single location's
    /// own TTL-bounded entry knowing anything about it -- a widget showing
    /// a reading that's still within its freshness window has no way to
    /// know the source it came from just started failing again, since nothing
    /// about that reading itself changes when a later attempt for a
    /// *different* location fails. Global, not per-location, same tradeoff
    /// `lastFetchedAt` already accepts (see `AQIRefreshController`'s own
    /// doc comment on it) -- deliberately simple over precise.
    private static let lastFailedFetchKey = "aqi-last-failed-fetch-at"

    private let store: SharedCacheStore

    public init(store: SharedCacheStore) {
        self.store = store
    }

    /// nil on a miss -- absent, undecodable, or past the *hard* threshold.
    /// A soft-expired-but-not-hard-expired entry still returns its reading
    /// here (bluegull-aqi-dc2.5) -- callers that need to distinguish fresh
    /// from stale want `freshness(for:)`, not this. A hard-expired entry is
    /// deleted here too, not just treated as a miss -- see the type's doc
    /// comment on retention bounding.
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

    /// nil if nothing is cached for this location (including a hard-expired,
    /// swept entry) -- distinct from `.expired`, which means an entry
    /// existed but is too old to show. See `get(for:)` for the reading
    /// itself.
    public func freshness(for location: Location, now: Date = Date()) -> AQIFreshness? {
        guard let data = store.data(forKey: Self.key(for: location)),
              let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data),
              !entry.isExpired(now: now) else { return nil }
        return entry.freshness(at: now)
    }

    public func put(
        _ reading: AQIReading,
        for location: Location,
        softTTL: TimeInterval = defaultSoftTTL,
        hardTTL: TimeInterval = defaultHardTTL,
        now: Date = Date()
    ) {
        let entry = AQICacheEntry(
            reading: reading,
            fetchedAt: now,
            softExpiresAt: now.addingTimeInterval(softTTL),
            hardExpiresAt: now.addingTimeInterval(hardTTL)
        )
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

    /// Records that a fetch attempt just failed (bluegull-aqi-e70.39) --
    /// the symmetric counterpart to `recordSuccessfulFetch` above. Callers
    /// write this on every failed attempt, not just once; only the most
    /// recent timestamp matters, same as the success side.
    public func recordFailedFetch(now: Date = Date()) {
        store.set(try? JSONEncoder().encode(now), forKey: Self.lastFailedFetchKey)
    }

    /// nil if a fetch has never failed. See `lastFailedFetchKey`'s own doc
    /// comment for why this is global rather than per-location.
    public func lastFailedFetchDate() -> Date? {
        guard let data = store.data(forKey: Self.lastFailedFetchKey) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    /// True exactly when the most recent fetch attempt -- by either
    /// process -- was a failure that hasn't been superseded by a later
    /// success. Compares timestamps rather than a single boolean flag so
    /// this can't drift out of sync if a caller records a failure without
    /// ever recording the success that resolves it (or vice versa) --
    /// there's only one source of truth (the two dates), not a third flag
    /// that also has to be kept consistent with them.
    public func isMostRecentFetchAttemptFailing(now: Date = Date()) -> Bool {
        guard let failedAt = lastFailedFetchDate() else { return false }
        guard let succeededAt = lastSuccessfulFetchDate() else { return true }
        return failedAt > succeededAt
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

    /// Same "most recent across every location" answer as `mostRecentEntry`,
    /// as a freshness rather than a reading -- see that method's own doc
    /// comment for when this fallback applies.
    public func mostRecentEntryFreshness(now: Date = Date()) -> AQIFreshness? {
        let myKeys = store.allKeys().filter { $0.hasPrefix(Self.keyPrefix) }
        var newest: AQICacheEntry?

        for key in myKeys {
            guard let data = store.data(forKey: key),
                  let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data),
                  !entry.isExpired(now: now) else { continue }
            if newest == nil || entry.fetchedAt > newest!.fetchedAt {
                newest = entry
            }
        }

        return newest?.freshness(at: now)
    }

    /// Records a successful live-GPS fetch under its own stable key
    /// (bluegull-aqi-mtm.20), independent of the coordinate-keyed entry
    /// `AQIFetchCoordinator` already writes via `put(_:for:)` -- GPS
    /// coordinates drift call-to-call, so there's no fixed coordinate key a
    /// "Current Location" reader could look up directly otherwise. Same
    /// TTL/expiry semantics as `put(_:for:)`.
    public func putCurrentLocation(
        _ reading: AQIReading,
        softTTL: TimeInterval = defaultSoftTTL,
        hardTTL: TimeInterval = defaultHardTTL,
        now: Date = Date()
    ) {
        let entry = AQICacheEntry(
            reading: reading,
            fetchedAt: now,
            softExpiresAt: now.addingTimeInterval(softTTL),
            hardExpiresAt: now.addingTimeInterval(hardTTL)
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: Self.currentLocationKey)
    }

    /// nil on a miss -- absent, undecodable, or past the hard threshold
    /// (deleted here too, same as `get(for:)`). This is the *specific*
    /// "what did live GPS resolve to most recently" answer -- see
    /// `currentLocationKey`'s doc comment for why a widget showing "Current
    /// Location" should prefer this over `mostRecentEntry()`.
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

    /// Same fresh/stale/expired distinction as `freshness(for:)`, for the
    /// "Current Location" slot.
    public func currentLocationFreshness(now: Date = Date()) -> AQIFreshness? {
        guard let data = store.data(forKey: Self.currentLocationKey),
              let entry = try? JSONDecoder().decode(AQICacheEntry.self, from: data),
              !entry.isExpired(now: now) else { return nil }
        return entry.freshness(at: now)
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
