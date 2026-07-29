"""Client for AirNow's Current Observations by Latitude/Longitude web service.

Uses the endpoint AirNow introduced 2026-06-17, NOT the classic
/aq/observation/latLong/current/ endpoint most tutorials and older code
reference -- EPA is retiring that one (and five siblings) on 2026-09-30. See
doc/DESIGN.md "Backend service" for how this was confirmed: a dated, merged
pyairnow migration PR, EPA's own official PDF notice, and a live test query.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

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
    url = f"{API_BASE_URL}?{params}"

    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_SECONDS) as response:  # nosec B310
            body = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        _raise_for_error_body(body, exc.code)
        raise AirNowError(f"AirNow returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise AirNowError(f"AirNow request failed: {exc.reason}") from exc

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
