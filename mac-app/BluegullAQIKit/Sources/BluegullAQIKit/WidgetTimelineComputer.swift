import Foundation

/// What a widget timeline entry needs -- deliberately not a WidgetKit
/// `TimelineEntry` itself (this package has no WidgetKit dependency, same
/// rationale as `AQIColor` having no SwiftUI dependency: platform-glue
/// types stay in the app targets, not here). The widget extension wraps
/// this in its own `TimelineEntry`-conforming type.
public struct WidgetTimelineSnapshot: Sendable, Equatable {
    public let date: Date
    public let reading: AQIReading?

    public init(date: Date, reading: AQIReading?) {
        self.date = date
        self.reading = reading
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
    /// "current location" (the widget can't resolve that itself -- see
    /// `AppGroupCache.mostRecentEntry()`'s own doc comment) and the
    /// pre-`mtm.3` unconfigured case.
    public func currentSnapshot(for location: Location? = nil, now: Date = Date()) -> WidgetTimelineSnapshot {
        let reading = location.map { cache.get(for: $0, now: now) } ?? cache.mostRecentEntry(now: now)
        return WidgetTimelineSnapshot(date: now, reading: reading)
    }

    public func nextReloadDate(after now: Date = Date()) -> Date {
        refreshScheduler.nextRefreshDate(after: now)
    }
}
