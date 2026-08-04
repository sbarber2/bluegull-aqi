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
    private let menuBarLocationMirror: SharedMenuBarLocationStore
    private var refreshTask: Task<Void, Never>?
    private var widgetSettleTask: Task<Void, Never>?

    // Much shorter than RefreshScheduler's ~1-hour cadence -- see
    // `widgetSettleLoop()`'s own doc comment (bluegull-aqi-mtm.21).
    private static let widgetSettleInterval: TimeInterval = 20

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
        widgetSettleTask = Task { [weak self] in
            await self?.widgetSettleLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshNow()
            let interval = scheduler.nextRefreshDate().timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(interval, 1)))
        }
    }

    /// A much shorter-interval companion to `runLoop()`'s hourly cadence,
    /// specifically for noticing a widget that was just placed or pointed
    /// at a new location (bluegull-aqi-mtm.21). The container app has no
    /// other signal tied to "a widget's configuration just changed" --
    /// the widget extension can't tell it directly (no background
    /// networking there to piggyback a request on) -- so this polls
    /// instead. Cheap to run often: `activeWidgetLocations()` is a local
    /// `WidgetCenter` query, not a network call, and
    /// `refreshWidgetLocations` below only actually fetches a genuine
    /// cache miss -- an already-valid entry is a no-op, so this doesn't
    /// multiply AirNow request volume the way unconditionally re-fetching
    /// on every tick would.
    private func widgetSettleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.widgetSettleInterval))
            await refreshWidgetLocations(mode: currentMode())
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
            guard let location = await resolve(menuBarSelection.pinnedLocation) else {
                throw LocationResolverError.locationUnavailable("current location unavailable")
            }
            menuBarLocation = location
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
        let handled: Set<Location> = Set([menuBarLocation?.rounded].compactMap { $0 })
        await refreshWidgetLocations(mode: mode, alreadyHandled: handled)
    }

    /// Fetches every placed widget's independently-configured location
    /// that's a genuine cache miss (bluegull-aqi-igu/mtm.21) -- skips
    /// anything already validly cached, so calling this often
    /// (`widgetSettleLoop`) doesn't re-fetch data that's still fresh.
    /// `alreadyHandled` lets `refreshNow()`'s own call skip a widget
    /// pointed at the same ~1km cell its menu bar fetch just handled in
    /// the same pass.
    private func refreshWidgetLocations(mode: DataSourceMode, alreadyHandled: Set<Location> = []) async {
        var handled = alreadyHandled
        var resolvedCurrentLocation: Location?
        func resolve(_ pinned: Location?) async -> Location? {
            if let pinned { return pinned }
            if let resolvedCurrentLocation { return resolvedCurrentLocation }
            let resolved = try? await locationResolver.currentLocation()
            resolvedCurrentLocation = resolved
            return resolved
        }

        for widgetPinnedLocation in await activeWidgetLocations() {
            guard let location = await resolve(widgetPinnedLocation) else { continue }
            guard handled.insert(location.rounded).inserted else { continue }
            // Skip a location that's already validly cached -- this is
            // what keeps `widgetSettleLoop`'s frequent polling cheap
            // instead of multiplying AirNow request volume.
            guard cache.get(for: location) == nil else { continue }
            // Best-effort: a failure here shouldn't touch `lastError`,
            // which describes the menu bar's own fetch above. The widget
            // just keeps showing whatever's still validly cached (or "No
            // Data") until a later attempt succeeds.
            guard let reading = try? await coordinator.fetch(location: location, mode: mode) else { continue }
            // Same current-location mirroring as the menu bar's own fetch
            // above, for a widget independently configured to "Current
            // Location" while the menu bar itself shows a pinned location
            // (bluegull-aqi-mtm.20).
            if widgetPinnedLocation == nil {
                cache.putCurrentLocation(reading)
            }
        }
    }

    /// On-demand fetch for a single location, for a consumer that notices
    /// a cache miss right now rather than waiting for either loop above
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
        guard let resolvedLocation, cache.get(for: resolvedLocation) == nil else { return }
        guard let reading = try? await coordinator.fetch(location: resolvedLocation, mode: currentMode()) else { return }
        if location == nil {
            cache.putCurrentLocation(reading)
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
