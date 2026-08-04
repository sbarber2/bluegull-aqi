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
/// Also keeps every currently-placed desktop widget's own independently-
/// configured location fresh (bluegull-aqi-igu), not just the menu bar's:
/// each widget instance's `SelectLocationIntent` (bluegull-aqi-mtm.3) can
/// point at a different pinned location than the menu bar shows
/// (bluegull-aqi-e70.21 -- deliberately separate selections, doc/
/// DESIGN.md), and the widget extension itself can never fetch (no
/// background networking there). Before this, a widget pointed anywhere
/// other than the menu bar's own current selection simply never got a
/// cache entry at all -- confirmed against a real Group Container dump
/// (bluegull-aqi-igu): a third pinned location, never selected in the
/// menu bar, had never been fetched even though a widget could be (and
/// visually appeared to be) configured to show it.
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
    /// scheduled attempt. Also refreshes every other location a placed
    /// widget is independently configured to show (bluegull-aqi-igu, see
    /// this type's own doc comment) -- those never update the observable
    /// properties below, which describe the menu bar's own display only.
    func refreshNow() async {
        let mode = currentMode()

        // Resolves live GPS at most once per call, however many callers
        // below (the menu bar's own selection, plus every placed widget)
        // ask for "current location" -- `pinned` is nil for that case.
        var resolvedCurrentLocation: Location?
        func resolve(_ pinned: Location?) async -> Location? {
            if let pinned { return pinned }
            if let resolvedCurrentLocation { return resolvedCurrentLocation }
            let resolved = try? await locationResolver.currentLocation()
            resolvedCurrentLocation = resolved
            return resolved
        }

        var menuBarLocation: Location?
        do {
            guard let location = await resolve(currentLocationSelection().pinnedLocation) else {
                throw LocationResolverError.locationUnavailable("current location unavailable")
            }
            menuBarLocation = location
            latestReading = try await coordinator.fetch(location: location, mode: mode)
            lastFetchedAt = cache.lastSuccessfulFetchDate()
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

        // `.rounded` matches AppGroupCache's own cache-key precision, so a
        // widget pointed at the same ~1km cell as the menu bar's own
        // selection doesn't trigger a second, redundant fetch.
        var handled: Set<Location> = Set([menuBarLocation?.rounded].compactMap { $0 })
        for widgetPinnedLocation in await activeWidgetLocations() {
            guard let location = await resolve(widgetPinnedLocation) else { continue }
            guard handled.insert(location.rounded).inserted else { continue }
            // Best-effort: a failure here shouldn't touch `lastError`,
            // which describes the menu bar's own fetch above. The widget
            // just keeps showing whatever's still validly cached (or "No
            // Data") until a later cycle succeeds.
            _ = try? await coordinator.fetch(location: location, mode: mode)
        }
    }

    /// Every location a currently-placed widget instance is configured to
    /// show (bluegull-aqi-mtm.3) -- `nil` per entry means "current
    /// location" (not-yet-configured or explicitly selected; both collapse
    /// to the same nil, same as `BluegullAQIWidgetTimelineProvider.entry
    /// (for:)`'s own handling of the intent). Empty on any WidgetCenter
    /// failure or if nothing's actually placed on the desktop -- this
    /// never blocks the menu bar's own fetch above.
    private func activeWidgetLocations() async -> [Location?] {
        guard let infos = try? await WidgetCenter.shared.currentConfigurations() else { return [] }
        return infos
            .filter { $0.kind == BluegullWidgetKind.aqi }
            .map { ($0.configuration as? SelectLocationIntent)?.location?.location }
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

private extension WidgetCenter {
    /// `getCurrentConfigurations` is completion-handler-only; wrapped here
    /// so `activeWidgetLocations()` above can just `await` it like
    /// everything else in this file's fetch path.
    func currentConfigurations() async throws -> [WidgetInfo] {
        try await withCheckedThrowingContinuation { continuation in
            getCurrentConfigurations { result in
                continuation.resume(with: result)
            }
        }
    }
}
