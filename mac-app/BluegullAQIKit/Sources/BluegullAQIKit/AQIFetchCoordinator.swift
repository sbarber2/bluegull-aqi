/// Errors from fetch orchestration/mode-selection itself, distinct from
/// `AirNowError` (the underlying HTTP client's errors).
public enum AQIFetchError: Error, Equatable, Sendable {
    /// Direct mode selected, but no API key has been saved yet
    /// (`AirNowAPIKeyStore`) -- the user needs to visit Settings.
    case noAPIKeyConfigured

    /// Service mode selected, but `BluegullServiceClient` doesn't exist yet
    /// (bluegull-aqi-10h.4, blocked on the backend's first deploy,
    /// bluegull-aqi-q9r.10). Surfaced explicitly rather than silently doing
    /// nothing or crashing -- Service mode is
    /// `DataSourceModeStore.defaultMode`, so a fresh install hits this until
    /// the user either switches to Direct mode or the backend ships.
    case serviceModeNotYetAvailable

    case airNowError(AirNowError)
}

/// Fetches a fresh `AQIReading` for a location using whichever client the
/// user's `DataSourceMode` selects, and writes a successful result into the
/// shared App Group cache the widget's `TimelineProvider` also reads
/// (bluegull-aqi-e70.7). Only `.direct` is wired to a real client today --
/// see `AQIFetchError.serviceModeNotYetAvailable`.
public struct AQIFetchCoordinator: Sendable {
    private let directClient: AirNowDirectClient
    private let apiKeyStore: AirNowAPIKeyStore
    private let cache: AppGroupCache

    public init(
        directClient: AirNowDirectClient = AirNowDirectClient(),
        apiKeyStore: AirNowAPIKeyStore = AirNowAPIKeyStore(),
        cache: AppGroupCache
    ) {
        self.directClient = directClient
        self.apiKeyStore = apiKeyStore
        self.cache = cache
    }

    /// Fetches, and on success writes the result to the cache keyed by
    /// `location` -- callers don't need a separate `cache.put` call.
    @discardableResult
    public func fetch(location: Location, mode: DataSourceMode) async throws -> AQIReading {
        switch mode {
        case .direct:
            return try await fetchDirect(location: location)
        case .service:
            throw AQIFetchError.serviceModeNotYetAvailable
        }
    }

    private func fetchDirect(location: Location) async throws -> AQIReading {
        let apiKey: String?
        do {
            apiKey = try apiKeyStore.load()
        } catch {
            throw AQIFetchError.noAPIKeyConfigured
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw AQIFetchError.noAPIKeyConfigured
        }

        do {
            let reading = try await directClient.fetchCurrentObservations(location: location, apiKey: apiKey)
            // Cache under reading.location, not the caller's `location` --
            // the client rounds internally (bluegull-aqi-10h.11) and
            // reading.location is the authoritative rounded value a
            // subsequent cache.get(for: someLocation.rounded) needs to
            // match.
            cache.put(reading, for: reading.location)
            return reading
        } catch let error as AirNowError {
            throw AQIFetchError.airNowError(error)
        }
    }
}
