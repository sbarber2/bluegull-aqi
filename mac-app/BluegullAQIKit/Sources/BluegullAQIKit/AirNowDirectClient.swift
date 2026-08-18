import Foundation

/// Client for AirNow's Current Observations by Latitude/Longitude web
/// service, called directly with a user-supplied API key (Direct mode --
/// see doc/DESIGN.md "Data-source modes"). Uses the endpoint AirNow
/// introduced 2026-06-17 (`current/ziplatlong`), confirmed live and
/// documented in bluegull-aqi-10h.19 -- NOT the classic `latLong/current`
/// endpoint most tutorials reference, which EPA is retiring 2026-09-30.
/// Mirrors `service/src/bluegull_aqi_service/airnow_client.py`'s logic,
/// since both call the same endpoint with the same error shape.
public struct AirNowDirectClient: Sendable {
    private static let baseURL = URL(string: "https://www.airnowapi.org/aq/observation/current/ziplatlong/")!

    private let urlSession: URLSession
    // UserDefaults isn't formally Sendable in the SDK, but Apple documents
    // it as safe to use from multiple threads -- same treatment as
    // `BluegullServiceClient`'s own `overrideDefaults`.
    private nonisolated(unsafe) let timeoutDefaults: UserDefaults?

    /// `urlSession` is injectable for testing -- there's no "AirNow Local"
    /// equivalent to DynamoDB Local, so unit tests mock at the URLSession
    /// layer (a custom URLProtocol) rather than hitting the live API,
    /// matching the Python client's own test approach (mocked
    /// urllib.request.urlopen, no live AirNow traffic in the test suite).
    /// `timeoutDefaults` is injectable for the same reason -- tests point
    /// it at an isolated suite instead of the real App Group one.
    public init(urlSession: URLSession = .shared, timeoutDefaults: UserDefaults? = RequestTimeoutStore.sharedDefaults) {
        self.urlSession = urlSession
        self.timeoutDefaults = timeoutDefaults
    }

    /// Fetches current NowCast observations for a location, one entry per
    /// pollutant. Returns AirNow's own fields exactly as received --
    /// bluegull-aqi-10h.17: never altered, never used to derive an AQI.
    ///
    /// `location` is rounded to ~1km precision before the request is built
    /// (bluegull-aqi-10h.11) -- AirNow never receives a precise coordinate,
    /// regardless of what precision the caller passed in.
    public func fetchCurrentObservations(location: Location, apiKey: String) async throws -> AQIReading {
        let location = location.rounded
        let request = try makeRequest(location: location, apiKey: apiKey)

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

        // Checked regardless of status code first -- AirNow returns some
        // errors (e.g. "no observations available for this location") with
        // an HTTP 200, matching the Python client's ordering.
        try Self.raiseForErrorBody(data: data, statusCode: httpResponse.statusCode)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AirNowError.httpError(statusCode: httpResponse.statusCode)
        }

        let pollutants: [PollutantReading]
        do {
            pollutants = try JSONDecoder().decode([PollutantReading].self, from: data)
        } catch {
            throw AirNowError.decodingFailed(error.localizedDescription)
        }

        return AQIReading(location: location, pollutants: pollutants)
    }

    private func makeRequest(location: Location, apiKey: String) throws -> URLRequest {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw AirNowError.unexpectedResponse
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "application/json"),
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "API_KEY", value: apiKey),
        ]
        guard let url = components.url else {
            throw AirNowError.unexpectedResponse
        }
        // bluegull-aqi-e70.43: resolved fresh on every request, not
        // captured once at init, so changing the timeout in Settings takes
        // effect on this client's next call.
        let timeout = RequestTimeoutStore.directTimeout(in: timeoutDefaults)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return request
    }

    /// AirNow's error body shape is `{"WebServiceError": [{"Message":
    /// "..."}]}` -- PascalCase, unlike the main response's camelCase, kept
    /// verbatim here (not renamed to Swift convention) for the same reason
    /// `PollutantReading` keeps `siteID`'s casing: exact correspondence to
    /// the wire format, no custom CodingKeys, no chance of a silent
    /// mismatch.
    private struct WebServiceErrorBody: Decodable {
        struct Entry: Decodable {
            let Message: String?
        }
        let WebServiceError: [Entry]
    }

    private static func raiseForErrorBody(data: Data, statusCode: Int) throws {
        guard let errorBody = try? JSONDecoder().decode(WebServiceErrorBody.self, from: data) else {
            return
        }
        let message = errorBody.WebServiceError.first?.Message ?? "Unknown error"
        throw AirNowError.webServiceError(statusCode: statusCode, message: message)
    }
}
