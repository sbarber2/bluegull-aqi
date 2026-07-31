import Foundation
import Observation
import BluegullAQIKit

/// Drives the container app's actual fetch loop (bluegull-aqi-e70.6/e70.7):
/// resolves the user's current location, fetches via whichever
/// `DataSourceMode` is selected, and writes a successful result to the
/// shared App Group cache the widget's `TimelineProvider` also reads, then
/// reschedules itself on `RefreshScheduler`'s jittered interval.
///
/// Deliberately a thin app-level wrapper, not unit tested itself -- the
/// same reasoning as `LocationPermissionRequester`'s own doc comment. The
/// actual fetch/cache/mode-selection logic lives in `AQIFetchCoordinator`
/// (`BluegullAQIKit`), which is unit tested with injected fakes.
@Observable
@MainActor
final class AQIRefreshController {
    private(set) var latestReading: AQIReading?
    private(set) var lastError: AQIFetchError?

    private let locationResolver: LocationResolver
    private let coordinator: AQIFetchCoordinator
    private let scheduler: RefreshScheduler
    private var refreshTask: Task<Void, Never>?

    /// nil if the App Group suite couldn't be opened -- same graceful-
    /// degradation as `UserDefaultsCacheStore` elsewhere; there's nowhere
    /// to cache a result or read a previous one, so this controller simply
    /// can't do its job.
    init?(
        locationResolver: LocationResolver = LocationResolver(),
        store: SharedCacheStore? = UserDefaultsCacheStore()
    ) {
        guard let store else { return nil }
        self.locationResolver = locationResolver
        let cache = AppGroupCache(store: store)
        coordinator = AQIFetchCoordinator(cache: cache)
        scheduler = RefreshScheduler(store: store)
        latestReading = cache.mostRecentEntry()
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
    /// first attempt right after location permission is granted, so a user
    /// doesn't wait up to an hour for the first real reading.
    func refreshNow() async {
        let mode = currentMode()
        do {
            let location = try await locationResolver.currentLocation()
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

    private func currentMode() -> DataSourceMode {
        guard let raw = UserDefaults.standard.string(forKey: DataSourceModeStore.userDefaultsKey),
              let mode = DataSourceMode(rawValue: raw) else {
            return DataSourceModeStore.defaultMode
        }
        return mode
    }
}
