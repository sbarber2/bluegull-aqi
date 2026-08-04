import Foundation

/// What a widget timeline entry needs -- deliberately not a WidgetKit
/// `TimelineEntry` itself (this package has no WidgetKit dependency, same
/// rationale as `AQIColor` having no SwiftUI dependency: platform-glue
/// types stay in the app targets, not here). The widget extension wraps
/// this in its own `TimelineEntry`-conforming type.
public struct WidgetTimelineSnapshot: Sendable, Equatable {
    public let date: Date
    public let reading: AQIReading?

    /// When a fetch last actually succeeded, anywhere -- independent of
    /// `reading`'s own per-location TTL, and still set even once `reading`
    /// has gone nil because that entry expired (bluegull-aqi-dc2.1). Powers
    /// distinguishing "never fetched" from "went stale" in the widget's
    /// empty state, instead of both collapsing to the same unqualified "No
    /// Data."
    public let lastSuccessfulFetchDate: Date?

    public init(date: Date, reading: AQIReading?, lastSuccessfulFetchDate: Date? = nil) {
        self.date = date
        self.reading = reading
        self.lastSuccessfulFetchDate = lastSuccessfulFetchDate
    }
}

/// The testable core of the widget's `TimelineProvider`
/// (bluegull-aqi-mtm.2), pulled into this package specifically so it's
/// unit-testable at all: a `TimelineProvider` living in an app-extension
/// target can't be linked against by a separate test target the way an app
/// target can (confirmed via a real link failure while writing
/// bluegull-aqi-mtm.7's tests -- `app-extension` products aren't linkable
/// libraries) -- extracting the actual logic here, where `BluegullAQIKitTests`
/// already has full test infrastructure, sidesteps that entirely rather
/// than fighting Xcode's `TEST_HOST`/`BUNDLE_LOADER` extension-hosting
/// configuration.
///
/// Composes `AppGroupCache.get(for:)`/`mostRecentEntry()` and
/// `RefreshScheduler.nextRefreshDate()` (bluegull-aqi-10h.10) for the
/// reload policy.
public struct WidgetTimelineComputer: Sendable {
    private let cache: AppGroupCache
    private let refreshScheduler: RefreshScheduler

    public init(store: SharedCacheStore) {
        cache = AppGroupCache(store: store)
        refreshScheduler = RefreshScheduler(store: store)
    }

    /// `location` is the widget instance's configured pin
    /// (bluegull-aqi-mtm.3, App Intents) -- when one is set, this looks up
    /// *only* that location's cache entry, never falling back to a
    /// different location's data (a user who picked "Work" should see "no
    /// data yet" rather than "Home"'s AQI by surprise). `nil` covers both
    /// "current location" (the widget can't resolve that itself) and the
    /// pre-`mtm.3` unconfigured case -- that reads `getCurrentLocation()`,
    /// the most recent live-GPS fetch specifically (bluegull-aqi-mtm.20),
    /// falling back to `mostRecentEntry()` (whatever's most recent, any
    /// location) only when GPS has never successfully resolved at all, e.g.
    /// a fresh install or permission never granted.
    public func currentSnapshot(for location: Location? = nil, now: Date = Date()) -> WidgetTimelineSnapshot {
        // `.rounded` -- `AQIFetchCoordinator` caches under the fetch
        // client's own rounded location (bluegull-aqi-10h.11), never the
        // caller's raw one, so a lookup with the widget's raw configured
        // pin missed every time (bluegull-aqi-nmn): every widget with a
        // distinct pinned location showed "Data Unavailable" forever, since
        // `reading` here was always nil despite a valid cache entry
        // existing under the rounded key.
        let reading = location.map { cache.get(for: $0.rounded, now: now) }
            ?? cache.getCurrentLocation(now: now)
            ?? cache.mostRecentEntry(now: now)
        return WidgetTimelineSnapshot(date: now, reading: reading, lastSuccessfulFetchDate: cache.lastSuccessfulFetchDate())
    }

    public func nextReloadDate(after now: Date = Date()) -> Date {
        refreshScheduler.nextRefreshDate(after: now)
    }
}
