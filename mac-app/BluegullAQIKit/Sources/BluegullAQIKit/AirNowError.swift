/// Errors from calling AirNow directly (`AirNowDirectClient`) or via the
/// BlueGull backend service (`BluegullServiceClient`, bluegull-aqi-10h.4).
/// Deliberately holds plain `String` descriptions rather than wrapping the
/// underlying `Error`/`URLResponse` types: keeps this Equatable and easy to
/// assert on in tests, matching the service side's `AirNowError` (a plain
/// message, not a wrapped exception).
public enum AirNowError: Error, Equatable, Sendable {
    /// The network request itself failed (no response at all) -- offline,
    /// DNS failure, timeout, etc.
    case requestFailed(String)

    /// A response arrived but wasn't a valid HTTP response.
    case unexpectedResponse

    /// AirNow returned a non-2xx status without a recognizable
    /// `WebServiceError` body.
    case httpError(statusCode: Int)

    /// AirNow's `{"WebServiceError": [{"Message": "..."}]}` error shape --
    /// checked regardless of HTTP status code, since AirNow returns some
    /// errors (e.g. "no observations available for this location") with a
    /// 200 status.
    case webServiceError(statusCode: Int, message: String)

    /// The response body wasn't the expected JSON shape.
    case decodingFailed(String)
}
