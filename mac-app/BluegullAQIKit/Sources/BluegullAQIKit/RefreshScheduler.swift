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
    public func nextRefreshDate(after now: Date = Date(), interval: TimeInterval = defaultInterval) -> Date {
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
