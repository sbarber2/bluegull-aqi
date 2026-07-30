"""Verifies bluegull-aqi-q9r.27: the AirNow key and raw/rounded coordinates
must never appear in log output, even when a request fails."""
import json
import logging
import urllib.error
from unittest.mock import patch

from bluegull_aqi_service import aqi_lookup, cache
from bluegull_aqi_service.airnow_client import AirNowError, fetch_current_observations
from bluegull_aqi_service.lambda_handler import lambda_handler

from .conftest import mock_urlopen_response

SECRET_KEY = "not-a-real-airnow-key-0000000000000000"
LAT, LON = 37.7749, -122.4194


def test_fetch_current_observations_never_logs_api_key(caplog):
    caplog.set_level(logging.DEBUG, logger="bluegull_aqi_service")
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value = mock_urlopen_response(json.dumps([{"nowcastAQI": 31}]).encode())
        fetch_current_observations(LAT, LON, SECRET_KEY)

    assert SECRET_KEY not in caplog.text
    assert "API_KEY" not in caplog.text


def test_fetch_current_observations_error_never_logs_api_key(caplog):
    caplog.set_level(logging.DEBUG, logger="bluegull_aqi_service")
    error_body = json.dumps({"WebServiceError": [{"Message": "Invalid API key"}]}).encode()
    http_error = urllib.error.HTTPError(url="http://example.com", code=401, msg="Unauthorized", hdrs=None, fp=None)
    http_error.read = lambda: error_body
    with patch("bluegull_aqi_service.airnow_client.urllib.request.urlopen", side_effect=http_error):
        try:
            fetch_current_observations(LAT, LON, SECRET_KEY)
        except AirNowError:
            pass

    assert SECRET_KEY not in caplog.text


def test_lambda_handler_success_never_logs_raw_coordinates(caplog):
    caplog.set_level(logging.DEBUG, logger="bluegull_aqi_service")
    with patch("bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi") as mock_get_aqi:
        mock_get_aqi.return_value = {"observations": [{"nowcastAQI": 31}], "cached": False}
        lambda_handler({"queryStringParameters": {"lat": str(LAT), "lon": str(LON)}}, None)

    assert str(LAT) not in caplog.text
    assert str(LON) not in caplog.text


def test_lambda_handler_error_never_logs_raw_coordinates(caplog):
    caplog.set_level(logging.DEBUG, logger="bluegull_aqi_service")
    with patch(
        "bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi",
        side_effect=AirNowError("Invalid API key"),
    ):
        response = lambda_handler({"queryStringParameters": {"lat": str(LAT), "lon": str(LON)}}, None)

    assert response["statusCode"] == 502
    assert str(LAT) not in caplog.text
    assert str(LON) not in caplog.text
    # The hash used for correlation should still show up -- proves logging
    # wasn't just deleted wholesale, only the raw values were redacted.
    assert cache.hash_location_key(cache.location_key(LAT, LON)) in caplog.text


def test_get_aqi_never_logs_raw_coordinates(caplog, monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    caplog.set_level(logging.DEBUG, logger="bluegull_aqi_service")
    lat, lon = 32.7767, -96.7970  # Dallas -- must be a real North American location

    cache.Cache().delete(cache.location_key(lat, lon))

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        mock_fetch.return_value = [{"nowcastAQI": 31}]
        aqi_lookup.get_aqi(lat, lon)  # cache miss
        aqi_lookup.get_aqi(lat, lon)  # cache hit

    assert str(lat) not in caplog.text
    assert str(lon) not in caplog.text
    assert cache.location_key(lat, lon) not in caplog.text
    assert cache.hash_location_key(cache.location_key(lat, lon)) in caplog.text


def test_hash_location_key_is_stable_and_not_reversible():
    key = cache.location_key(LAT, LON)
    digest = cache.hash_location_key(key)

    assert digest == cache.hash_location_key(key)
    assert digest != cache.hash_location_key(cache.location_key(LAT + 1, LON))
    assert key not in digest


def test_log_level_does_not_unmute_botocore_debug_logging():
    """Regression guard: LOG_LEVEL must only widen our own logger tree, not
    root -- otherwise LOG_LEVEL=DEBUG (the local-dev .env.example default)
    would also enable botocore's DEBUG logging, which dumps raw DynamoDB item
    bodies (i.e. the unhashed LocationKey) straight to the console."""
    assert logging.getLogger("botocore").getEffectiveLevel() >= logging.WARNING
    assert logging.getLogger("urllib3").getEffectiveLevel() >= logging.WARNING
    assert logging.getLogger("bluegull_aqi_service").getEffectiveLevel() <= logging.INFO
