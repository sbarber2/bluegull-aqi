import Foundation
import Observation
import BluegullAQIKit

/// Drives the container app's actual fetch loop (bluegull-aqi-e70.6/e70.7):
/// resolves whichever location the menu bar is currently set to show
/// (bluegull-aqi-e70.21 -- current location by default, or a specific
/// pinned location), fetches via whichever `DataSourceMode` is selected,
/// and writes a successful result to the shared App Group cache the
/// widget's `TimelineProvider` also reads, then reschedules itself on
/// `RefreshScheduler`'s jittered interval.
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

    private let locationResolver: LocationResolver
    private let pinnedLocationsStore: PinnedLocationsStore
    private let coordinator: AQIFetchCoordinator
    private let scheduler: RefreshScheduler
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
        let cache = AppGroupCache(store: store)
        coordinator = AQIFetchCoordinator(cache: cache)
        scheduler = RefreshScheduler(store: store)
        latestReading = cache.mostRecentEntry()
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
    /// scheduled attempt.
    func refreshNow() async {
        let mode = currentMode()
        do {
            let location = try await resolveLocation(currentLocationSelection())
            latestReading = try await coordinator.fetch(location: location, mode: mode)
            lastError = nil
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

    /// A pinned selection resolves to its stored Location directly (no
    /// GPS involved); .currentLocation is the only case that needs the
    /// live resolver.
    private func resolveLocation(_ selection: LocationOption) async throws -> Location {
        if let pinned = selection.pinnedLocation {
            return pinned
        }
        return try await locationResolver.currentLocation()
    }

    private func currentLocationSelection() -> LocationOption {
        let options = WidgetLocationOptions.all(from: pinnedLocationsStore)
        let id = UserDefaults.standard.string(forKey: MenuBarLocationSelectionStore.userDefaultsKey)
        return MenuBarLocationSelectionStore.selection(id: id, availableOptions: options)
    }

    private func currentMode() -> DataSourceMode {
        guard let raw = UserDefaults.standard.string(forKey: DataSourceModeStore.userDefaultsKey),
              let mode = DataSourceMode(rawValue: raw) else {
            return DataSourceModeStore.defaultMode
        }
        return mode
    }
}
