import Foundation
import Observation
import WidgetKit
import BluegullAQIKit

/// Drives the container app's actual fetch loop (bluegull-aqi-e70.6/e70.7):
/// resolves whichever location the menu bar is currently set to show
/// (bluegull-aqi-e70.21 -- current location by default, or a specific
/// pinned location), fetches via whichever `DataSourceMode` is selected,
/// and writes a successful result to the shared App Group cache the
/// widget's `TimelineProvider` also reads, then reschedules itself on
/// `RefreshScheduler`'s jittered interval.
///
/// Concerned only with the **menu bar's own** displayed location for pinned
/// locations, as of bluegull-aqi-mtm.24. Placed widgets pinned to a specific
/// location fetch their own directly in the widget extension process, so
/// this no longer enumerates or refreshes them. The previous arrangement
/// (bluegull-aqi-igu, then bluegull-aqi-o4b's `WidgetRequestedLocationsStore`
/// relay plus a 20s settle loop) existed only because the widget couldn't
/// fetch; once it could, that whole path became redundant work -- measured
/// 2026-08-05 as roughly 2x the necessary outbound request volume, with both
/// processes fetching the same locations.
///
/// One exception: "Current Location" widgets still can't fetch for
/// themselves (no location entitlement in the extension), so `refreshNow()`
/// also keeps that specific cache slot warm every cycle regardless of the
/// menu bar's own selection (bluegull-aqi-e10) -- without that, a widget on
/// Current Location would depend entirely on the menu bar happening to also
/// be set to Current Location, and show Data Unavailable forever otherwise.
///
/// Deliberately a thin app-level wrapper, not unit tested itself -- the
/// same reasoning as `LocationPermissionRequester`'s own doc comment. The
/// actual fetch/cache/mode-selection logic lives in `AQIFetchCoordinator`
/// (`BluegullAQIKit`), which is unit tested with injected fakes; so is the
/// location-selection resolution logic this reads
/// (`MenuBarLocationSelectionStore.selection(id:availableOptions:)`).
@Observable
@MainActor
final class AQIRefreshController {
    private(set) var latestReading: AQIReading?
    private(set) var lastError: AQIFetchError?

    // bluegull-aqi-dc2.1: when a fetch last actually succeeded, independent
    // of `latestReading`'s own per-location cache TTL -- lets the UI show
    // "updated X ago" (and keep showing `latestReading` through a
    // transient failure) instead of the failure hiding otherwise-good data
    // with no explanation of how old it is.
    private(set) var lastFetchedAt: Date?

    /// Live freshness of `latestReading` specifically (bluegull-aqi-e70.31)
    /// -- Steve was explicit the menu bar, as a single glanceable number
    /// with no room to qualify it, must never show data old enough to be
    /// misleading; past the soft TTL it must stop showing a number at all,
    /// not just look identical to a fresh one.
    ///
    /// Deliberately NOT derived from `lastFetchedAt` above, even though that
    /// looks like the obvious signal: `lastFetchedAt`
    /// (`AppGroupCache.lastSuccessfulFetchDate`) is a GLOBAL "some fetch,
    /// somewhere, by either process, succeeded" timestamp -- shared with the
    /// popover's own "last updated" caption (bluegull-aqi-dc2.1), where that
    /// global scope is exactly what's wanted. Gating THIS reading's
    /// staleness on it would be wrong: a placed widget in another process
    /// fetching a completely different pinned location bumps that same
    /// timestamp, which would make a genuinely stale `latestReading` look
    /// fresh -- silently reintroducing the bug this bead exists to fix.
    ///
    /// Computed on every access against `latestReading.location`'s own cache
    /// entry and the wall clock, rather than cached at fetch time, so it
    /// can't drift out of sync between refresh cycles the way a stored flag
    /// could. `AppGroupCache.freshness(for:)` never returns `.expired` (see
    /// that type's own doc comment) -- `get`'s cascade already stops
    /// returning a reading past the hard threshold, so there's nothing left
    /// to be `.expired` about by the time anything reaches here.
    var latestReadingFreshness: AQIFreshness? {
        guard let latestReading else { return nil }
        return cache.freshness(for: latestReading.location.rounded, now: Date())
    }

    private let pinnedLocationsStore: PinnedLocationsStore
    private let coordinator: AQIFetchCoordinator
    private let cache: AppGroupCache
    private let scheduler: RefreshScheduler
    private let menuBarLocationMirror: SharedMenuBarLocationStore
    private let helperStatusStore: LocationHelperStatusStore
    private var refreshTask: Task<Void, Never>?

    // bluegull-aqi-e70.47: drives RefreshScheduler's fast-retry cadence --
    // counts only the menu bar's own selected-location fetch (the `do`
    // block's `AQIFetchError` catch below), not the separate "keep Current
    // Location warm" fetch further down, which already swallows its own
    // errors via `try?` and was never what `lastError` tracked either.
    private var consecutiveFailureCount = 0

    /// nil if the App Group suite couldn't be opened -- same graceful-
    /// degradation as `UserDefaultsCacheStore` elsewhere; there's nowhere
    /// to cache a result or read a previous one, so this controller simply
    /// can't do its job.
    ///
    /// `startOnInit` defaults to true and actually starts the fetch loop
    /// here, at construction -- same pattern as
    /// `LocationPermissionRequester`'s `requestOnInit`. Originally this was
    /// triggered by a `.task` on `AQIPopoverView` instead, which was a real
    /// bug: that view is the *popover's content*, which SwiftUI only builds
    /// the first time the user actually clicks the menu bar icon -- so the
    /// menu bar label showed no AQI value at all until after a first click,
    /// found by Steve in a real run. `false` exists for callers (tests,
    /// previews) that want construction without the side effect.
    /// No `locationResolver` parameter any more (bluegull-aqi-hib.6): this
    /// type used to hold one purely to call `currentLocation()`, and under
    /// Option 1 the app resolves no GPS at all. Removing the dependency
    /// rather than leaving it unused is the point -- it makes "the app never
    /// asks CoreLocation for a fix" structurally true instead of true only
    /// as long as nobody adds a call back.
    init?(
        store: SharedCacheStore? = UserDefaultsCacheStore(),
        startOnInit: Bool = true
    ) {
        guard let store else { return nil }
        pinnedLocationsStore = PinnedLocationsStore(store: store)
        cache = AppGroupCache(store: store)
        coordinator = AQIFetchCoordinator(cache: cache)
        scheduler = RefreshScheduler(store: store)
        menuBarLocationMirror = SharedMenuBarLocationStore(store: store)
        helperStatusStore = LocationHelperStatusStore(store: store)
        latestReading = cache.mostRecentEntry()
        lastFetchedAt = cache.lastSuccessfulFetchDate()
        if startOnInit {
            start()
        }
    }

    /// Starts the fetch-then-reschedule loop. Idempotent -- a second call
    /// while a loop is already running is a no-op, so callers (e.g. a
    /// permission-status change firing an immediate retry) don't need to
    /// track whether they've already started it.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshNow()
            let interval = scheduler.nextRefreshDate(consecutiveFailures: consecutiveFailureCount).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(interval, 1)))
        }
    }

    /// Fetches immediately, outside the scheduled cadence -- used for the
    /// first attempt right after location permission is granted, and after
    /// the user changes which location the menu bar shows
    /// (bluegull-aqi-e70.21), so neither waits up to an hour for the next
    /// scheduled attempt. Placed widgets pinned to a specific location fetch
    /// their own (bluegull-aqi-mtm.24) -- but a widget configured to
    /// "Current Location" still can't (no location entitlement in the
    /// extension), so this loop also keeps that cache slot fresh on every
    /// cycle below, independent of whatever the menu bar itself is showing
    /// (bluegull-aqi-e10).
    /// Live background-refresh status for the popover (bluegull-aqi-hib.7).
    /// Recomputed on access rather than cached, for the same reason
    /// `latestReadingFreshness` is: a user can switch the background item
    /// off in System Settings at any moment and nothing notifies us, so a
    /// stored flag would go quietly wrong.
    var backgroundRefreshStatus: BackgroundRefreshStatus {
        helperStatusStore.backgroundRefreshStatus()
    }

    /// Polls `SMAppService` and writes the answer into the App Group.
    ///
    /// Polling is the only mechanism available: there is NO notification
    /// when a user disables a background item in Login Items & Extensions.
    /// The same mitigation `LaunchAtLoginToggle` already applies to the
    /// main app, with the same caveat -- it narrows the window in which the
    /// app is wrong, it does not close it.
    ///
    /// Writing it down (rather than just reading it where needed) is what
    /// lets the widget agree with the app: `SMAppService` is unavailable to
    /// an app extension, so the widget cannot ask this question itself.
    func refreshHelperAvailability() {
        helperStatusStore.recordAvailability(LocationHelperController.availability)
    }

    func refreshNow() async {
        // Before anything reads the status this cycle, and before the
        // current-location path below decides whether to bother poking a
        // helper that may not be there at all.
        refreshHelperAvailability()
        let mode = currentMode()

        // Mirrors the menu bar's current selection into the App Group
        // (bluegull-aqi-mtm.20): `MenuBarLocationSelectionStore` itself is
        // deliberately `UserDefaults.standard` (container-app-only), which
        // the widget extension process can't read -- so a newly-placed
        // widget's `LocationOptionQuery.defaultResult()` couldn't otherwise
        // see it. App Intents only calls `defaultResult()` once, at
        // placement time, so this mirror only ever seeds a *starting*
        // value for a new widget -- it's not a live link, and later menu
        // bar changes don't touch already-placed widgets.
        let menuBarSelection = currentLocationSelection()
        menuBarLocationMirror.save(persistenceID: menuBarSelection.persistenceID)

        do {
            let reading: AQIReading
            if let pinned = menuBarSelection.pinnedLocation {
                reading = try await coordinator.fetch(location: pinned, mode: mode)
            } else {
                // bluegull-aqi-hib.6: the app no longer resolves GPS or
                // fetches for the current-location case. It reads what the
                // helper wrote, and asks the helper to go again if that is
                // stale. One grant, one fetcher.
                reading = try await currentLocationReading()
            }
            latestReading = reading
            lastFetchedAt = cache.lastSuccessfulFetchDate()
            lastError = nil
            consecutiveFailureCount = 0
            // A widget pinned to the same location the menu bar just
            // fetched now has fresher data available than whatever it last
            // rendered. Nudging is the only sanctioned way to surface that
            // before its own reload policy fires (bluegull-aqi-mtm.12).
            // Advisory, not a repaint -- and unlike the deleted settle
            // loop, this fires at most once per menu bar refresh.
            WidgetCenter.shared.reloadTimelines(ofKind: BluegullWidgetKind.aqi)
        } catch let error as AQIFetchError {
            lastError = error
            consecutiveFailureCount += 1
            // bluegull-aqi-e70.39's own signal (cache.recordFailedFetch(),
            // called inside AQIFetchCoordinator on this same failure)
            // updates the shared cache correctly, but nothing else tells a
            // placed widget to go re-check it -- confirmed live: the
            // failure landed in the App Group right on schedule, but the
            // desktop widget still showed the old, not-yet-downgraded
            // state because WidgetKit only naturally re-evaluates on its
            // own reload policy (up to an hour away). Same nudge as the
            // success branch above, just reached from the other outcome.
            WidgetCenter.shared.reloadTimelines(ofKind: BluegullWidgetKind.aqi)
        } catch {
            // No location to fetch for -- the helper has no grant, or
            // couldn't be reached. Leave latestReading as whatever was last
            // cached; don't clear a still-valid reading just because this
            // attempt found nothing. The popover explains the recoverable
            // version of this itself (bluegull-aqi-hib.6's
            // `needsLocationSetup`), so there is nothing to put in
            // `lastError`, which is for *fetch* failures.
            lastError = nil
        }

        // bluegull-aqi-e10's "keep the Current Location slot warm while the
        // menu bar is pinned elsewhere" block USED to live here, and is gone
        // under bluegull-aqi-hib.6. It existed because nothing else could
        // fill that slot: the widget extension can't resolve GPS, and this
        // controller only touched the slot when the menu bar itself happened
        // to be on Current Location. The helper now owns the slot outright
        // and refreshes it on its own schedule regardless of what the menu
        // bar shows, which is the same guarantee by a better route -- and
        // keeping the old block would mean the app fetching for the
        // current-location case, which is exactly what hib.6 forbids.
    }

    /// The current-location reading, read rather than resolved
    /// (bluegull-aqi-hib.6).
    ///
    /// The helper agent is the only process that resolves GPS, so the app's
    /// role here is to read the slot the helper writes and, if what it finds
    /// is not current, ask the helper to go again. Poking is cheap on both
    /// sides: launchd starts the helper on the connection, and the helper's
    /// own job returns `.skippedStillFresh` without resolving GPS or
    /// fetching if the slot turns out to be fine after all.
    ///
    /// Throws when there is still nothing afterwards -- no grant yet, the
    /// agent switched off in System Settings, or the helper simply
    /// unreachable. All three are states the popover offers to fix rather
    /// than fetch failures, which is why this throws a location error rather
    /// than an `AQIFetchError`.
    private func currentLocationReading() async throws -> AQIReading {
        if cache.currentLocationFreshness() == .fresh, let fresh = cache.getCurrentLocation() {
            return fresh
        }
        // Only worth poking something that is actually there. A poke at a
        // deregistered agent just waits out its deadline.
        guard LocationHelperController.availability == .enabled else {
            throw LocationResolverError.locationUnavailable("background updates unavailable")
        }
        if await LocationHelperController.refreshNow() == nil {
            // Registered and enabled, yet no answer -- the one failure
            // SMAppService cannot see, so it is recorded here, where it is
            // the only place it becomes observable (bluegull-aqi-hib.7).
            helperStatusStore.recordAvailability(.unreachable)
        }
        guard let reading = cache.getCurrentLocation() else {
            throw LocationResolverError.locationUnavailable("no current-location reading available")
        }
        return reading
    }

    /// On-demand fetch for a single location, for a consumer that notices
    /// a cache miss right now rather than waiting for the scheduled loop
    /// (bluegull-aqi-mtm.21) -- currently just `WidgetDetailView`, which
    /// runs in this same process and has direct access, unlike the widget
    /// extension itself. A no-op if `location` (or live GPS, for nil)
    /// already has a valid cached entry.
    func fetchIfNeeded(for location: Location?) async {
        // nil means "current location", which this process no longer
        // resolves (bluegull-aqi-hib.6) -- the helper does, and
        // `currentLocationReading()` is the one path to it. Before hib.6
        // this branch called `locationResolver.currentLocation()` directly,
        // which is a second CoreLocation user in the app and so a second
        // permission prompt waiting to happen.
        guard let location else {
            _ = try? await currentLocationReading()
            return
        }
        // `.rounded` -- AppGroupCache is keyed by rounded coords
        // (bluegull-aqi-10h.11/nmn).
        guard cache.get(for: location.rounded) == nil else { return }
        _ = try? await coordinator.fetch(location: location, mode: currentMode())
    }

    private func currentLocationSelection() -> LocationOption {
        let options = WidgetLocationOptions.all(from: pinnedLocationsStore)
        let id = UserDefaults.standard.string(forKey: MenuBarLocationSelectionStore.userDefaultsKey)
        return MenuBarLocationSelectionStore.selection(id: id, availableOptions: options)
    }

    // App Group-backed as of bluegull-aqi-mtm.24, so this and the widget
    // extension's own fetch path read the same selection.
    private func currentMode() -> DataSourceMode {
        DataSourceModeStore.currentMode()
    }
}
