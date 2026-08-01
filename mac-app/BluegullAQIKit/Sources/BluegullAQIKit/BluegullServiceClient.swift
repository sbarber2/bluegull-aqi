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
/// `baseURL` is hardcoded to the dev stack (bluegull-aqi-q9r.10) --
/// deliberately, since that's the only environment actually deployed
/// right now. Must switch to the prod custom domain before an App Store
/// release; tracked as bluegull-aqi-fw4.6 so it isn't silently forgotten.
public struct BluegullServiceClient: Sendable {
    private static let baseURL = URL(string: "https://dev.aqi.bluegull.solutions/aqi")!
    private static let requestTimeout: TimeInterval = 10

    private let urlSession: URLSession

    /// `urlSession` is injectable for testing, same reasoning as
    /// `AirNowDirectClient`'s own doc comment -- no live traffic against
    /// either AirNow or our own backend in the test suite.
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
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
        let request = try Self.makeRequest(location: location)

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

    private static func makeRequest(location: Location) throws -> URLRequest {
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
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
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

    private static func errorForFailedResponse(data: Data, statusCode: Int) -> AirNowError {
        let message = (try? JSONDecoder().decode(ServiceErrorBody.self, from: data))?.error ?? "Unknown error"
        return .webServiceError(statusCode: statusCode, message: message)
    }
}
