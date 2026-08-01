/// Errors from fetch orchestration/mode-selection itself, distinct from
/// `AirNowError` (the underlying HTTP client's errors).
public enum AQIFetchError: Error, Equatable, Sendable {
    /// Direct mode selected, but no API key has been saved yet
    /// (`AirNowAPIKeyStore`) -- the user needs to visit Settings.
    case noAPIKeyConfigured

    case airNowError(AirNowError)

    /// Service mode's backend returned 429 -- either its own global
    /// cache-miss budget (`rate_limiter.py`) or API Gateway's stage
    /// throttling rejecting the request before the Lambda ever runs
    /// (bluegull-aqi-dc2.2). Distinct from the generic `.airNowError` case
    /// specifically so the message can nudge toward Direct mode, which
    /// isn't subject to this shared limit -- that nudge wouldn't make sense
    /// for a Direct-mode 429 (AirNow's *own* rate limit), so
    /// `AQIFetchCoordinator.fetchService`, not `AirNowError` itself, is
    /// what decides when to use this case instead of `.airNowError`.
    case serviceModeRateLimited

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
        case .serviceModeRateLimited:
            return "BlueGull's shared service is busy. Try again shortly, or switch to Direct mode in Settings for your own AirNow key with no shared limit."
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
            // Independent of the per-location entry above -- survives that
            // entry's own TTL expiry, powering the "last updated X ago"/
            // stale-cache UI (bluegull-aqi-dc2.1).
            cache.recordSuccessfulFetch()
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
            cache.recordSuccessfulFetch()
            return reading
        } catch let error as AirNowError {
            // bluegull-aqi-dc2.2: a 429 here is the shared backend's own
            // budget/throttling, not AirNow's -- worth a distinct,
            // actionable message (see AQIFetchError.serviceModeRateLimited)
            // rather than surfacing whatever raw text (if any) came back.
            if Self.isRateLimited(error) {
                throw AQIFetchError.serviceModeRateLimited
            }
            throw AQIFetchError.airNowError(error)
        }
    }

    private static func isRateLimited(_ error: AirNowError) -> Bool {
        switch error {
        case .webServiceError(let statusCode, _), .httpError(let statusCode):
            return statusCode == 429
        case .requestFailed, .unexpectedResponse, .decodingFailed:
            return false
        }
    }
}
