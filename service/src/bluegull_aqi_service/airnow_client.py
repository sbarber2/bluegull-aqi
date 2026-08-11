"""Client for AirNow's Current Observations by Latitude/Longitude web service.

Uses the endpoint AirNow introduced 2026-06-17, NOT the classic
/aq/observation/latLong/current/ endpoint most tutorials and older code
reference -- EPA is retiring that one (and five siblings) on 2026-09-30. See
doc/DESIGN.md "Backend service" for how this was confirmed: a dated, merged
pyairnow migration PR, EPA's own official PDF notice, and a live test query.
"""
import json
import logging
import urllib.error
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

API_BASE_URL = "https://www.airnowapi.org/aq/observation/current/ziplatlong/"
REQUEST_TIMEOUT_SECONDS = 10


class AirNowError(Exception):
    """Raised when AirNow's API returns an error or an unusable response."""


def fetch_current_observations(latitude: float, longitude: float, api_key: str) -> list[dict]:
    """Fetch current NowCast observations for a location, one entry per pollutant.

    Returns AirNow's response fields exactly as received (dateObserved,
    hourObserved, localTimeZone, reportingAreaName, siteID, siteName,
    parameterName, nowcastAQI, aqiCategoryName, reportingAgency,
    lookupBehavior, consideredMonitors, lookupBoundary) -- never altered,
    never used to derive an AQI ourselves (bluegull-aqi-10h.17).
    """
    params = urllib.parse.urlencode(
        {
            "format": "application/json",
            "latitude": latitude,
            "longitude": longitude,
            "API_KEY": api_key,
        }
    )
    # The query string carries API_KEY as a plain parameter -- `url` must never
    # be passed to logger, an exception message, or anything else that could
    # surface it in CloudWatch Logs or a client response (bluegull-aqi-q9r.27).
    # Log calls below reference only the static, keyless API_BASE_URL.
    url = f"{API_BASE_URL}?{params}"

    logger.info("Requesting AirNow observations from %s", API_BASE_URL)
    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:  # nosec B310
            body = response.read()
    except urllib.error.HTTPError as exc:
        logger.warning("AirNow request to %s failed with HTTP %s", API_BASE_URL, exc.code)
        body = exc.read()
        _raise_for_error_body(body, exc.code)
        raise AirNowError(f"AirNow returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        logger.warning("AirNow request to %s failed: %s", API_BASE_URL, exc.reason)
        raise AirNowError(f"AirNow request failed: {exc.reason}") from exc
    # A *read*-phase timeout raises bare TimeoutError, which is NOT a
    # subclass of URLError and so is not caught above (bluegull-aqi-q9r.40).
    # Confirmed against a real stalling HTTP server, not assumed:
    # `isinstance(exc, urllib.error.URLError)` is False. Only a
    # *connection*-phase timeout gets wrapped into URLError by urllib, which
    # is why this looked covered and wasn't.
    #
    # Letting it escape un-wrapped was the actual bug: nothing upstream
    # catches TimeoutError, so it bypassed aqi_lookup._refresh's
    # serve-stale-on-AirNow-failure fallback (which keys on AirNowError) and
    # lambda_handler's 502 mapping, surfacing as a bare API Gateway 500 with
    # good stale data sitting unused in DynamoDB. A timeout is the most
    # likely way AirNow becomes unreachable, so it has to land in exactly
    # the same bucket as any other AirNow failure.
    #
    # `exc` is deliberately not interpolated into the message -- unlike
    # URLError.reason it can carry the socket address, and the URL itself
    # carries API_KEY (bluegull-aqi-q9r.27, CLAUDE.md secrets rule).
    except TimeoutError as exc:
        logger.warning("AirNow request to %s timed out", API_BASE_URL)
        raise AirNowError(f"AirNow request timed out after {REQUEST_TIMEOUT_SECONDS}s") from exc

    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise AirNowError("AirNow response was not valid JSON") from exc

    _raise_for_error_body(data, 200)

    if not isinstance(data, list):
        raise AirNowError(f"Unexpected AirNow response type: {type(data).__name__}")

    return data


def _raise_for_error_body(body, status_code: int) -> None:
    """Raise AirNowError if the response body is AirNow's WebServiceError shape."""
    if isinstance(body, (bytes, str)):
        try:
            body = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            return
    if isinstance(body, dict) and "WebServiceError" in body:
        errors = body["WebServiceError"]
        message = errors[0]["Message"] if errors and "Message" in errors[0] else str(errors)
        raise AirNowError(f"AirNow error (HTTP {status_code}): {message}")
