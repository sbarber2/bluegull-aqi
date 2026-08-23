import Foundation

/// Computes when the next AQI refresh should happen, spreading load across
/// all installs rather than every one waking at the top of the hour and
/// synchronizing into a server-side spike (bluegull-aqi-10h.10).
///
/// Each install derives a stable offset within the refresh interval from a
/// per-install value, persisted via the same `SharedCacheStore` -- so the
/// container app and widget extension see the same schedule -- rather than
/// regenerated on every call. Re-randomizing each time would make the
/// refresh interval irregular instead of a consistent per-install cadence
/// that's simply out of phase with every other install's.
public struct RefreshScheduler: Sendable {
    public static let defaultInterval: TimeInterval = 3600

    /// bluegull-aqi-e70.47: how soon to retry after a fetch failure, instead
    /// of waiting for the next slot on `defaultInterval`'s hourly cadence --
    /// confirmed nothing else in the fetch path (`AppGroupCache.recordFailedFetch`,
    /// `AQIFetchCoordinator`) retries sooner than the caller's own schedule,
    /// so a transient error could otherwise cost up to an hour of no updates
    /// by design, not by bug. This is the delay after the *first* failure;
    /// subsequent retries back off from here (see `nextRefreshDate`).
    public static let fastRetryInterval: TimeInterval = 60

    /// Ceiling the backoff grows to and then holds at. Measured directly
    /// (2026-08-22, dev backend logs cross-referenced against other
    /// installs' offsets) that an AirNow timeout clustered around one
    /// install's scheduled minute clears roughly 11-12 minutes later, not
    /// "well under a minute" as originally assumed here -- doubling every
    /// retry from `fastRetryInterval` would either overshoot that window in
    /// one jump or take too many attempts to get there, so growth is capped
    /// well below it and `maxFastRetries` does the work of covering the gap.
    public static let maxFastRetryInterval: TimeInterval = 240

    /// Caps how long the fast-retry cadence runs before falling back to the
    /// normal schedule. 6 retries growing 60, 120, 240, 240, 240, 240
    /// accumulate to ~19 minutes -- comfortable margin over the ~11-12
    /// minute recovery window above, while an outage that outlasts that many
    /// attempts is no longer "transient," and retrying indefinitely would
    /// just hammer a backend that's genuinely down (and burn this account's
    /// still-tight Lambda concurrency, bluegull-aqi-q9r.35).
    public static let maxFastRetries = 6

    private static let offsetKey = "refresh-schedule-install-offset"

    private let store: SharedCacheStore

    public init(store: SharedCacheStore) {
        self.store = store
    }

    /// A stable value in `[0, interval)`, generated once per install and
    /// persisted thereafter.
    public func installOffset(interval: TimeInterval = defaultInterval) -> TimeInterval {
        if let data = store.data(forKey: Self.offsetKey),
           let stored = try? JSONDecoder().decode(Double.self, from: data),
           stored >= 0, stored < interval {
            return stored
        }

        let fresh = Double.random(in: 0..<interval)
        if let data = try? JSONEncoder().encode(fresh) {
            store.set(data, forKey: Self.offsetKey)
        }
        return fresh
    }

    /// The next refresh time strictly after `now`, on this install's
    /// stable, interval-spaced schedule (`installOffset`, `installOffset +
    /// interval`, `installOffset + 2*interval`, ...).
    ///
    /// `consecutiveFailures` (bluegull-aqi-e70.47) short-circuits that
    /// schedule to an exponential backoff off `fastRetryInterval` (doubling
    /// each attempt, capped at `maxFastRetryInterval`) after a recent run of
    /// failures, up to `maxFastRetries` attempts -- `0` (the default)
    /// reproduces the exact prior behavior, so every existing caller (in
    /// particular `WidgetTimelineComputer`, which has no notion of the
    /// *container* app's own fetch outcome to pass here) is unaffected.
    public func nextRefreshDate(
        after now: Date = Date(),
        interval: TimeInterval = defaultInterval,
        consecutiveFailures: Int = 0
    ) -> Date {
        if consecutiveFailures > 0, consecutiveFailures <= Self.maxFastRetries {
            let backoff = Self.fastRetryInterval * pow(2, Double(consecutiveFailures - 1))
            return now.addingTimeInterval(min(backoff, Self.maxFastRetryInterval))
        }
        let phase = installOffset(interval: interval)
        let epoch = now.timeIntervalSince1970
        let k = ((epoch - phase) / interval).rounded(.down) + 1
        var candidate = Date(timeIntervalSince1970: phase + k * interval)
        // Date stores time relative to 2001, not 1970 -- converting a
        // "seconds since 1970" Double (~1.7-2 billion for any date this
        // package will ever see) into that internal representation loses
        // some low-order precision. Two raw `timeIntervalSince1970` values
        // that look safely different before conversion can land on the
        // exact same Date after it. Comparing (and, if needed, bumping)
        // `candidate` against `now` here -- both already-constructed Date
        // values, both already through that same conversion -- keeps the
        // "strictly after" check in one consistent precision domain instead
        // of trusting the pre-conversion arithmetic to predict it.
        while candidate <= now {
            candidate = candidate.addingTimeInterval(interval)
        }
        return candidate
    }
}
