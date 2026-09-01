import Foundation

/// The location helper agent's entire unit of work (bluegull-aqi-hib.4):
/// resolve live GPS, fetch AQI through whichever `DataSourceMode` the user
/// selected, and write the result into the shared App Group cache -- both
/// the coordinate-keyed entry (via `AQIFetchCoordinator`) and the dedicated
/// current-location slot a "Current Location" widget reads directly.
///
/// Lives here, in the package, rather than in the helper executable, for
/// the same reason `AQIFetchCoordinator` does: the helper process itself is
/// almost impossible to unit test -- it only ever runs because launchd
/// decided to start it -- so everything that can be pulled out of it and
/// tested with injected fakes should be. What is left in the executable is
/// launchd plumbing (activity check-in, transactions, mach service), which
/// bluegull-aqi-hib.9 verifies by observation instead.
///
/// Deliberately does NOT request location authorization. Settling and
/// asking are different acts (see `SystemLocationProvider`); the ask is
/// bluegull-aqi-hib.6's first-run flow, which has to hold a transaction
/// across an unbounded human decision and needs to happen at a moment the
/// user has just asked for Current Location -- neither of which is true of
/// a 3am scheduled wake. With no grant this reports `.notAuthorized` and
/// does nothing else, which is the honest input bluegull-aqi-hib.7 needs.
public struct HelperRefreshJob: Sendable {
    /// What one wake actually did. Every case is a normal outcome, not an
    /// exception -- a helper woken with no grant, or no network, has not
    /// malfunctioned, and the caller's job is to log it and end its
    /// transaction either way.
    public enum Outcome: Sendable, Equatable {
        case refreshed(AQIReading)
        /// The cached current-location reading was still within its soft
        /// TTL, so nothing was fetched -- see `run(now:)`.
        case skippedStillFresh
        /// No location grant. Expected before bluegull-aqi-hib.6's
        /// first-run flow has run, and after a user revokes it.
        case notAuthorized
        /// Authorized, but no fix -- CoreLocation reported a failure, or
        /// went silent past `SystemLocationProvider`'s own deadline
        /// (bluegull-aqi-10h.22).
        case locationUnavailable(LocationResolverError)
        case fetchFailed(AQIFetchError)

        /// Short, stable, log/XPC-safe label. Deliberately carries no
        /// coordinates and no reading values -- this crosses a process
        /// boundary into the unified log, where it is world-readable.
        public var label: String {
            switch self {
            case .refreshed: "refreshed"
            case .skippedStillFresh: "skipped-still-fresh"
            case .notAuthorized: "not-authorized"
            case .locationUnavailable: "location-unavailable"
            case .fetchFailed: "fetch-failed"
            }
        }
    }

    private let locationResolver: LocationResolver
    private let coordinator: AQIFetchCoordinator
    private let cache: AppGroupCache
    private let currentMode: @Sendable () -> DataSourceMode

    /// nil if the App Group suite couldn't be opened -- same graceful
    /// degradation as `UserDefaultsCacheStore` and `AQIRefreshController`:
    /// there is nowhere to write a result, so there is no job to do.
    public init?(
        locationResolver: LocationResolver = LocationResolver(),
        store: SharedCacheStore? = UserDefaultsCacheStore()
    ) {
        guard let store else { return nil }
        let cache = AppGroupCache(store: store)
        self.init(
            locationResolver: locationResolver,
            coordinator: AQIFetchCoordinator(cache: cache),
            cache: cache
        )
    }

    /// Designated init, for tests -- `coordinator` and `cache` must be
    /// backed by the same store, or the freshness check below reads a
    /// different cache from the one the fetch writes.
    public init(
        locationResolver: LocationResolver,
        coordinator: AQIFetchCoordinator,
        cache: AppGroupCache,
        currentMode: @escaping @Sendable () -> DataSourceMode = { DataSourceModeStore.currentMode() }
    ) {
        self.locationResolver = locationResolver
        self.coordinator = coordinator
        self.cache = cache
        self.currentMode = currentMode
    }

    /// One wake's worth of work. Never throws: every failure is a value,
    /// because the caller has a launchd transaction to end and an activity
    /// to mark done regardless of how this turned out.
    public func run(now: Date = Date()) async -> Outcome {
        // Checked BEFORE resolving GPS, not after: a wake that finds fresh
        // data should cost nothing at all, and a GPS fix is the expensive
        // half of this job in both power and time.
        //
        // This is also what makes the wake interval and the fetch interval
        // separable (see the plist's own comment). The activity fires more
        // often than the data changes so that grace-period slop can never
        // leave the slot soft-stale for a whole extra cycle; this check is
        // what stops that extra frequency from turning into extra requests.
        // `.stale` deliberately DOES fetch -- past the soft TTL is exactly
        // when a replacement is wanted (bluegull-aqi-dc2.5).
        if cache.currentLocationFreshness(now: now) == .fresh {
            return .skippedStillFresh
        }

        let location: Location
        do {
            location = try await locationResolver.currentLocation()
        } catch LocationResolverError.permissionDenied {
            return .notAuthorized
        } catch let error as LocationResolverError {
            return .locationUnavailable(error)
        } catch {
            return .locationUnavailable(.locationUnavailable(error.localizedDescription))
        }

        do {
            // Writes the coordinate-keyed entry and records the global
            // success/failure timestamps itself (bluegull-aqi-e70.39), so
            // this deliberately doesn't duplicate any of that.
            let reading = try await coordinator.fetch(location: location, mode: currentMode())
            // The separate, stable slot a "Current Location" widget looks
            // up directly (bluegull-aqi-mtm.20) -- GPS coordinates drift
            // call to call, so there is no fixed coordinate key it could
            // read instead. Same write `AQIRefreshController` already makes
            // when the menu bar is on Current Location; under
            // bluegull-aqi-hib.6 this becomes the only process making it.
            cache.putCurrentLocation(reading, now: now)
            return .refreshed(reading)
        } catch let error as AQIFetchError {
            return .fetchFailed(error)
        } catch {
            return .fetchFailed(.airNowError(.requestFailed(error.localizedDescription)))
        }
    }
}
