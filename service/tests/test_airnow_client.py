"""Unit tests for the AirNow client. All network calls stubbed -- no live
AirNow traffic in the test suite."""
import json
import urllib.error
from unittest.mock import MagicMock, patch

import pytest

from bluegull_aqi_service.airnow_client import AirNowError, fetch_current_observations

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


def _mock_response(body_bytes):
    mock_resp = MagicMock()
    mock_resp.read.return_value = body_bytes
    mock_resp.__enter__.return_value = mock_resp
    mock_resp.__exit__.return_value = False
    return mock_resp


def test_fetch_current_observations_success():
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = _mock_response(json.dumps(SAMPLE_RESPONSE).encode())
        result = fetch_current_observations(37.7749, -122.4194, "fake-key")
    assert result == SAMPLE_RESPONSE
    assert result[0]["reportingAgency"] == "Bay Area Air District"


def test_fetch_current_observations_web_service_error():
    error_body = json.dumps({"WebServiceError": [{"Message": "Invalid API key"}]}).encode()
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = _mock_response(error_body)
        with pytest.raises(AirNowError, match="Invalid API key"):
            fetch_current_observations(37.7749, -122.4194, "bad-key")


def test_fetch_current_observations_http_error():
    error_body = json.dumps({"WebServiceError": [{"Message": "Invalid API key"}]}).encode()
    http_error = urllib.error.HTTPError(url="http://example.com", code=401, msg="Unauthorized", hdrs=None, fp=None)
    http_error.read = lambda: error_body
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen", side_effect=http_error):
        with pytest.raises(AirNowError, match="Invalid API key"):
            fetch_current_observations(37.7749, -122.4194, "bad-key")


def test_fetch_current_observations_unexpected_type():
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = _mock_response(json.dumps({"unexpected": "dict"}).encode())
        with pytest.raises(AirNowError, match="Unexpected AirNow response type"):
            fetch_current_observations(37.7749, -122.4194, "fake-key")
