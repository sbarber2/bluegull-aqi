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

    /// `reading`'s own freshness (bluegull-aqi-dc2.5) -- nil exactly when
    /// `reading` is nil, `.fresh`/`.stale` otherwise (never `.expired`:
    /// `AppGroupCache.get`'s cascade already stops returning a reading past
    /// the hard threshold, at which point there's nothing left to be
    /// `.expired` about). Lets a surface show a present-but-aged reading
    /// differently from a current one, instead of both looking identical.
    public let freshness: AQIFreshness?

    /// Why a CURRENT-LOCATION widget has nothing fresh to show
    /// (bluegull-aqi-hib.7) -- `.working` for every pinned widget, always,
    /// since pinned locations need no location grant at all and are
    /// genuinely unaffected by any of this.
    ///
    /// Carried through the snapshot rather than read by the widget itself
    /// because the widget CANNOT read it: the underlying signal is
    /// `SMAppService.status`, which app extensions cannot query. The app
    /// records it into the App Group and this passes it along, which is
    /// what makes the two surfaces agree instead of each guessing.
    public let backgroundRefresh: BackgroundRefreshStatus

    public init(
        date: Date,
        reading: AQIReading?,
        lastSuccessfulFetchDate: Date? = nil,
        freshness: AQIFreshness? = nil,
        backgroundRefresh: BackgroundRefreshStatus = .working
    ) {
        self.date = date
        self.reading = reading
        self.lastSuccessfulFetchDate = lastSuccessfulFetchDate
        self.freshness = freshness
        self.backgroundRefresh = backgroundRefresh
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
    private let helperStatus: LocationHelperStatusStore

    public init(store: SharedCacheStore) {
        cache = AppGroupCache(store: store)
        refreshScheduler = RefreshScheduler(store: store)
        helperStatus = LocationHelperStatusStore(store: store)
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
        // Same cascade, same short-circuit-on-a-specific-location shape as
        // `reading` above (bluegull-aqi-dc2.5) -- see that computation's own
        // comment for why a configured pin never falls through to a
        // different location's freshness either.
        var freshness = location.map { cache.freshness(for: $0.rounded, now: now) }
            ?? cache.currentLocationFreshness(now: now)
            ?? cache.mostRecentEntryFreshness(now: now)
        // bluegull-aqi-e70.39: a reading still within its own TTL is
        // exactly as untrustworthy as a stale one if the most recent fetch
        // attempt -- by either process -- actually failed. Reuses the
        // existing .stale treatment (the aged badge/caption every widget
        // layout already renders) rather than inventing a new visual --
        // the cross-process counterpart to the menu bar's own e70.37 fix,
        // needed here specifically because a Current Location widget never
        // fetches for itself and has no other way to learn the active
        // source just started failing.
        if freshness == .fresh, cache.isMostRecentFetchAttemptFailing(now: now) {
            freshness = .stale
        }
        return WidgetTimelineSnapshot(
            date: now,
            reading: reading,
            lastSuccessfulFetchDate: cache.lastSuccessfulFetchDate(),
            freshness: freshness,
            // Only a nil `location` -- "Current Location" -- is affected.
            // A widget pinned to a named place keeps working with no
            // location grant at all (bluegull-aqi-hib.12), so reporting a
            // problem on one would be telling the user something is wrong
            // with a thing that is working (bluegull-aqi-hib.7).
            backgroundRefresh: location == nil ? helperStatus.backgroundRefreshStatus() : .working
        )
    }

    public func nextReloadDate(after now: Date = Date()) -> Date {
        refreshScheduler.nextRefreshDate(after: now)
    }
}
