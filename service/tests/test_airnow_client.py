"""Unit tests for the AirNow client. All network calls stubbed -- no live
AirNow traffic in the test suite."""
import json
import urllib.error
from unittest.mock import patch

import pytest

from bluegull_aqi_service.airnow_client import AirNowError, fetch_current_observations

from .conftest import mock_urlopen_response

SAMPLE_RESPONSE = [
    {
        "dateObserved": "2026-07-29",
        "hourObserved": "14:00",
        "localTimeZone": "PDT",
        "reportingAreaName": "San Francisco",
        "siteID": "060750005",
        "siteName": "San Francisco",
        "parameterName": "PM2.5",
        "nowcastAQI": 31,
        "aqiCategoryName": "Good",
        "reportingAgency": "Bay Area Air District",
        "lookupBehavior": "Closest Reading By Pollutant",
        "consideredMonitors": "All",
        "lookupBoundary": "50 Miles",
    }
]


def test_fetch_current_observations_success():
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = mock_urlopen_response(json.dumps(SAMPLE_RESPONSE).encode())
        result = fetch_current_observations(37.7749, -122.4194, "fake-key")
    assert result == SAMPLE_RESPONSE
    assert result[0]["reportingAgency"] == "Bay Area Air District"


def test_fetch_current_observations_web_service_error():
    error_body = json.dumps({"WebServiceError": [{"Message": "Invalid API key"}]}).encode()
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = mock_urlopen_response(error_body)
        with pytest.raises(AirNowError, match="Invalid API key"):
            fetch_current_observations(37.7749, -122.4194, "bad-key")


def test_fetch_current_observations_http_error():
    error_body = json.dumps({"WebServiceError": [{"Message": "Invalid API key"}]}).encode()
    http_error = urllib.error.HTTPError(url="http://example.com", code=401, msg="Unauthorized", hdrs=None, fp=None)
    http_error.read = lambda: error_body
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen", side_effect=http_error):
        with pytest.raises(AirNowError, match="Invalid API key"):
            fetch_current_observations(37.7749, -122.4194, "bad-key")


def test_fetch_current_observations_url_error():
    """Connection-phase failures arrive as URLError and must become AirNowError."""
    with patch(
        "bluegull_aqi_service.airnow_client.urllib.request.urlopen",
        side_effect=urllib.error.URLError("connection refused"),
    ):
        with pytest.raises(AirNowError, match="AirNow request failed"):
            fetch_current_observations(37.7749, -122.4194, "fake-key")


def test_fetch_current_observations_read_timeout():
    """bluegull-aqi-q9r.40: a read-phase timeout raises bare TimeoutError, which
    is NOT a URLError subclass, so it used to escape un-wrapped -- bypassing the
    serve-stale fallback and surfacing as an API Gateway 500."""
    assert not issubclass(TimeoutError, urllib.error.URLError)  # the whole reason this bug existed
    with patch(
        "bluegull_aqi_service.airnow_client.urllib.request.urlopen",
        side_effect=TimeoutError("timed out"),
    ):
        with pytest.raises(AirNowError, match="timed out"):
            fetch_current_observations(37.7749, -122.4194, "fake-key")


def test_read_timeout_message_does_not_leak_request_details():
    """The AirNow URL carries API_KEY, so nothing derived from the failed
    request may reach the exception message (CLAUDE.md secrets rule)."""
    with patch(
        "bluegull_aqi_service.airnow_client.urllib.request.urlopen",
        side_effect=TimeoutError("timed out contacting 203.0.113.7:443"),
    ):
        with pytest.raises(AirNowError) as excinfo:
            fetch_current_observations(37.7749, -122.4194, "super-secret-key")
    message = str(excinfo.value)
    assert "super-secret-key" not in message
    assert "203.0.113.7" not in message


def test_fetch_current_observations_unexpected_type():
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = mock_urlopen_response(json.dumps({"unexpected": "dict"}).encode())
        with pytest.raises(AirNowError, match="Unexpected AirNow response type"):
            fetch_current_observations(37.7749, -122.4194, "fake-key")
