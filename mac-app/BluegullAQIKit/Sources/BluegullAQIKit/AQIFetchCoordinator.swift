/// Errors from fetch orchestration/mode-selection itself, distinct from
/// `AirNowError` (the underlying HTTP client's errors).
public enum AQIFetchError: Error, Equatable, Sendable {
    /// Direct mode selected, but no API key has been saved yet
    /// (`AirNowAPIKeyStore`) -- the user needs to visit Settings.
    case noAPIKeyConfigured

    case airNowError(AirNowError)

    /// User-facing text (bluegull-aqi-e70.24) -- found genuinely missing:
    /// switching to Service mode silently failed every fetch with no UI
    /// indication why, making the whole app look broken/unresponsive
    /// rather than "this one mode isn't ready yet." Now moot for
    /// `.serviceModeNotYetAvailable` specifically (bluegull-aqi-10h.4
    /// wired up a real client), but the pattern -- and `.airNowError`'s
    /// message -- still matters for every other failure.
    public var userMessage: String {
        switch self {
        case .noAPIKeyConfigured:
            return "Enter your AirNow API key in Settings to use Direct mode."
        case .airNowError(let error):
            return error.userMessage
        }
    }
}

/// Fetches a fresh `AQIReading` for a location using whichever client the
/// user's `DataSourceMode` selects, and writes a successful result into the
/// shared App Group cache the widget's `TimelineProvider` also reads
/// (bluegull-aqi-e70.7). Both `.direct` (`AirNowDirectClient`) and
/// `.service` (`BluegullServiceClient`, bluegull-aqi-10h.4) are real as of
/// bluegull-aqi-q9r.10's dev deploy.
public struct AQIFetchCoordinator: Sendable {
    private let directClient: AirNowDirectClient
    private let serviceClient: BluegullServiceClient
    private let apiKeyStore: AirNowAPIKeyStore
    private let cache: AppGroupCache

    public init(
        directClient: AirNowDirectClient = AirNowDirectClient(),
        serviceClient: BluegullServiceClient = BluegullServiceClient(),
        apiKeyStore: AirNowAPIKeyStore = AirNowAPIKeyStore(),
        cache: AppGroupCache
    ) {
        self.directClient = directClient
        self.serviceClient = serviceClient
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
            return try await fetchService(location: location)
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

    private func fetchService(location: Location) async throws -> AQIReading {
        do {
            let reading = try await serviceClient.fetchCurrentObservations(location: location)
            // Same reason as fetchDirect: cache under the client's own
            // rounded location, not the caller's.
            cache.put(reading, for: reading.location)
            return reading
        } catch let error as AirNowError {
            throw AQIFetchError.airNowError(error)
        }
    }
}
