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
/// Concerned only with the **menu bar's own** displayed location, as of
/// bluegull-aqi-mtm.24. Placed widgets now fetch their own configured
/// locations directly in the widget extension process, so this no longer
/// enumerates or refreshes them. The previous arrangement (bluegull-aqi-igu,
/// then bluegull-aqi-o4b's `WidgetRequestedLocationsStore` relay plus a 20s
/// settle loop) existed only because the widget couldn't fetch; once it
/// could, that whole path became redundant work -- measured 2026-08-05 as
/// roughly 2x the necessary outbound request volume, with both processes
/// fetching the same locations.
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

    private let locationResolver: LocationResolver
    private let pinnedLocationsStore: PinnedLocationsStore
    private let coordinator: AQIFetchCoordinator
    private let cache: AppGroupCache
    private let scheduler: RefreshScheduler
    private let menuBarLocationMirror: SharedMenuBarLocationStore
    private var refreshTask: Task<Void, Never>?

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
    init?(
        locationResolver: LocationResolver = LocationResolver(),
        store: SharedCacheStore? = UserDefaultsCacheStore(),
        startOnInit: Bool = true
    ) {
        guard let store else { return nil }
        self.locationResolver = locationResolver
        pinnedLocationsStore = PinnedLocationsStore(store: store)
        cache = AppGroupCache(store: store)
        coordinator = AQIFetchCoordinator(cache: cache)
        scheduler = RefreshScheduler(store: store)
        menuBarLocationMirror = SharedMenuBarLocationStore(store: store)
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
            let interval = scheduler.nextRefreshDate().timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(interval, 1)))
        }
    }

    /// Fetches immediately, outside the scheduled cadence -- used for the
    /// first attempt right after location permission is granted, and after
    /// the user changes which location the menu bar shows
    /// (bluegull-aqi-e70.21), so neither waits up to an hour for the next
    /// scheduled attempt. Concerns only the menu bar's own location: placed
    /// widgets fetch their own (bluegull-aqi-mtm.24).
    func refreshNow() async {
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

        // `pinned` is nil for the "current location" case; this resolves
        // live GPS at most once per call.
        var resolvedCurrentLocation: Location?
        func resolve(_ pinned: Location?) async -> Location? {
            if let pinned { return pinned }
            if let resolvedCurrentLocation { return resolvedCurrentLocation }
            let resolved = try? await locationResolver.currentLocation()
            resolvedCurrentLocation = resolved
            return resolved
        }

        do {
            guard let location = await resolve(menuBarSelection.pinnedLocation) else {
                throw LocationResolverError.locationUnavailable("current location unavailable")
            }
            let reading = try await coordinator.fetch(location: location, mode: mode)
            latestReading = reading
            // nil selection means the menu bar itself is showing live GPS
            // -- mirror that into the dedicated current-location slot
            // (bluegull-aqi-mtm.20) so a widget configured for "Current
            // Location" can read it directly instead of guessing via
            // mostRecentEntry().
            if menuBarSelection.pinnedLocation == nil {
                cache.putCurrentLocation(reading)
            }
            lastFetchedAt = cache.lastSuccessfulFetchDate()
            lastError = nil
            // A widget pinned to the same location the menu bar just
            // fetched now has fresher data available than whatever it last
            // rendered. Nudging is the only sanctioned way to surface that
            // before its own reload policy fires (bluegull-aqi-mtm.12).
            // Advisory, not a repaint -- and unlike the deleted settle
            // loop, this fires at most once per menu bar refresh.
            WidgetCenter.shared.reloadTimelines(ofKind: BluegullWidgetKind.aqi)
        } catch let error as AQIFetchError {
            lastError = error
        } catch {
            // LocationResolverError or anything else -- no location to
            // fetch for. Leave latestReading as whatever was last cached;
            // don't clear a still-valid reading just because this attempt
            // couldn't resolve a location.
            lastError = nil
        }
    }

    /// On-demand fetch for a single location, for a consumer that notices
    /// a cache miss right now rather than waiting for the scheduled loop
    /// (bluegull-aqi-mtm.21) -- currently just `WidgetDetailView`, which
    /// runs in this same process and has direct access, unlike the widget
    /// extension itself. A no-op if `location` (or live GPS, for nil)
    /// already has a valid cached entry.
    func fetchIfNeeded(for location: Location?) async {
        let resolvedLocation: Location?
        if let location {
            resolvedLocation = location
        } else {
            resolvedLocation = try? await locationResolver.currentLocation()
        }
        // `.rounded` -- AppGroupCache is keyed by rounded coords
        // (bluegull-aqi-10h.11/nmn).
        guard let resolvedLocation, cache.get(for: resolvedLocation.rounded) == nil else { return }
        guard let reading = try? await coordinator.fetch(location: resolvedLocation, mode: currentMode()) else { return }
        if location == nil {
            cache.putCurrentLocation(reading)
        }
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
