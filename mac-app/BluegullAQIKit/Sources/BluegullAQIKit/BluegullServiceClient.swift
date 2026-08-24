import Foundation

/// Client for the BlueGull backend service (Service mode -- see
/// doc/DESIGN.md "Data-source modes"): calls *our own* Lambda-backed proxy
/// instead of AirNow directly. No API key parameter -- unlike
/// `AirNowDirectClient`, the backend holds its own AirNow key (AWS SSM),
/// which is the whole point of Service mode being "no setup required."
///
/// Reuses `AirNowError`, not a separate error type -- see that type's own
/// doc comment, which already scoped it to cover both clients. The wire
/// response shape differs from AirNow's own endpoint though:
/// `service/src/bluegull_aqi_service/lambda_handler.py` wraps the
/// pollutant array as `{"observations": [...], "cached": bool}`, and
/// error bodies are `{"error": "..."}`, not AirNow's own
/// `{"WebServiceError": [...]}` shape.
///
/// `defaultBaseURL` is the prod custom domain (bluegull-aqi-fw4.6, switched
/// 2026-08-24 once the prod stack existed to point at -- see
/// doc/DESIGN.md). Steve's own dev machine stays on the dev stack via the
/// hidden `overrideDefaults` field below, not a build-time flag.
///
/// `overrideDefaults` (bluegull-aqi-e70.28) lets a hidden dev-only Settings
/// field redirect requests elsewhere -- see `DevServiceURLOverrideStore`'s
/// own doc comment for why that's safe to leave wired in even in a shipping
/// build. Resolved fresh on every request via `resolvedBaseURL`, not
/// captured once at init, so flipping the override in Settings takes effect
/// on this client's next call even though `AQIFetchCoordinator` (and in
/// turn `AQIRefreshController`) construct one `BluegullServiceClient` and
/// reuse it for the app's whole run rather than rebuilding it per fetch.
///
/// That same `overrideDefaults` instance also backs the configurable
/// request timeout (bluegull-aqi-e70.43) -- both are App Group-suite
/// UserDefaults, so one injected instance covers both rather than adding a
/// second, functionally-identical parameter.
public struct BluegullServiceClient: Sendable {
    private static let defaultBaseURL = URL(string: "https://aqi.bluegull.solutions/aqi")!

    private let urlSession: URLSession
    // UserDefaults isn't formally Sendable in the SDK, but Apple documents
    // it as safe to use from multiple threads -- same treatment as
    // `UserDefaultsCacheStore`'s own `defaults` property.
    private nonisolated(unsafe) let overrideDefaults: UserDefaults?

    /// `urlSession` is injectable for testing, same reasoning as
    /// `AirNowDirectClient`'s own doc comment -- no live traffic against
    /// either AirNow or our own backend in the test suite. `overrideDefaults`
    /// is injectable for the same reason: tests point it at an isolated
    /// suite instead of the real App Group one.
    public init(urlSession: URLSession = .shared, overrideDefaults: UserDefaults? = DevServiceURLOverrideStore.sharedDefaults) {
        self.urlSession = urlSession
        self.overrideDefaults = overrideDefaults
    }

    /// Fetches current NowCast observations for a location via the
    /// backend, one entry per pollutant -- same never-altered contract as
    /// `AirNowDirectClient.fetchCurrentObservations` (bluegull-aqi-10h.17),
    /// since the backend itself passes AirNow's fields through unchanged
    /// (`service/src/bluegull_aqi_service/aqi_lookup.py`).
    ///
    /// `location` is rounded to ~1km precision before the request is built
    /// (bluegull-aqi-10h.11), matching `AirNowDirectClient` -- the backend
    /// rounds server-side too (its own cache-key precision), but this
    /// client doesn't rely on that; it never sends a precise coordinate
    /// regardless of what the server does with it.
    public func fetchCurrentObservations(location: Location) async throws -> AQIReading {
        let location = location.rounded
        let request = try makeRequest(location: location)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AirNowError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AirNowError.unexpectedResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.errorForFailedResponse(data: data, statusCode: httpResponse.statusCode)
        }

        let decoded: ServiceResponse
        do {
            decoded = try JSONDecoder().decode(ServiceResponse.self, from: data)
        } catch {
            throw AirNowError.decodingFailed(error.localizedDescription)
        }

        return AQIReading(location: location, pollutants: decoded.observations)
    }

    private func makeRequest(location: Location) throws -> URLRequest {
        let baseURL = DevServiceURLOverrideStore.resolvedBaseURL(fallback: Self.defaultBaseURL, in: overrideDefaults)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AirNowError.unexpectedResponse
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(location.latitude)),
            URLQueryItem(name: "lon", value: String(location.longitude)),
        ]
        guard let url = components.url else {
            throw AirNowError.unexpectedResponse
        }
        // bluegull-aqi-e70.43: resolved fresh on every request, same
        // reasoning as baseURL just above.
        let timeout = RequestTimeoutStore.serviceTimeout(in: overrideDefaults)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return request
    }

    /// `lambda_handler._response`'s success shape:
    /// `{"observations": [...pollutant dicts...], "cached": bool}`.
    private struct ServiceResponse: Decodable {
        let observations: [PollutantReading]
        let cached: Bool
    }

    /// `lambda_handler._response`'s error shape (400/429/502):
    /// `{"error": "..."}` -- deliberately never the raw upstream AirNow
    /// message (`lambda_handler.py` redacts that itself before this
    /// client ever sees it).
    private struct ServiceErrorBody: Decodable {
        let error: String
    }

    // bluegull-aqi-e70.38: "No error details in response body" instead of
    // "Unknown error" -- we DO know something specific here (a non-2xx
    // response arrived; its body just didn't match lambda_handler.py's own
    // `{"error": "..."}` contract, e.g. API Gateway's own throttling/
    // gateway-error responses, which never reach the handler at all). Not
    // user-facing itself -- `AQIFetchError.serviceModeError` builds the
    // actual displayed message from the status code, not this string -- but
    // still worth being honest about for anything that logs it directly.
    private static func errorForFailedResponse(data: Data, statusCode: Int) -> AirNowError {
        let message = (try? JSONDecoder().decode(ServiceErrorBody.self, from: data))?.error
            ?? "No error details in response body"
        return .webServiceError(statusCode: statusCode, message: message)
    }
}
