"""Handler-level tests. AQI lookup is stubbed here -- see test_aqi_lookup.py
for the real cache/AirNow orchestration, and test_airnow_client.py for the
AirNow parsing itself. Full API Gateway event fixtures are bluegull-aqi-q9r.14."""
import json
from unittest.mock import patch

import pytest

from bluegull_aqi_service.airnow_client import AirNowError
from bluegull_aqi_service.coverage import OutOfCoverageError
from bluegull_aqi_service.lambda_handler import lambda_handler
from bluegull_aqi_service.rate_limiter import RateLimitExceededError


def test_missing_params_returns_400():
    response = lambda_handler({"queryStringParameters": None}, None)
    assert response["statusCode"] == 400


def test_missing_lon_returns_400():
    response = lambda_handler({"queryStringParameters": {"lat": "37.7749"}}, None)
    assert response["statusCode"] == 400


def test_non_numeric_params_returns_400():
    response = lambda_handler({"queryStringParameters": {"lat": "abc", "lon": "-122"}}, None)
    assert response["statusCode"] == 400


def test_successful_lookup_returns_200():
    with patch("bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi") as mock_get_aqi:
        mock_get_aqi.return_value = {"observations": [{"nowcastAQI": 31}], "cached": False}
        response = lambda_handler({"queryStringParameters": {"lat": "37.7749", "lon": "-122.4194"}}, None)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["observations"][0]["nowcastAQI"] == 31
    mock_get_aqi.assert_called_once_with(37.7749, -122.4194)


def test_airnow_error_returns_502_without_echoing_raw_message():
    with patch(
        "bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi",
        side_effect=AirNowError("Invalid API key for upstream request to https://secret-looking-url"),
    ):
        response = lambda_handler({"queryStringParameters": {"lat": "37.7749", "lon": "-122.4194"}}, None)

    assert response["statusCode"] == 502
    body = json.loads(response["body"])
    assert "secret-looking-url" not in body["error"]
    assert "Invalid API key" not in body["error"]


def test_unhandled_exception_type_would_escape_the_handler():
    """bluegull-aqi-q9r.40 guard. The handler catches OutOfCoverageError,
    AirNowError and RateLimitExceededError with no broad `except`, so any other
    exception escapes and API Gateway turns it into a bare 500 -- which is
    exactly how an unwrapped TimeoutError produced a 500 in production while
    good stale data sat unused. This pins that structural fact: anything the
    client can raise must be normalized into AirNowError *below* this layer
    (see airnow_client), because this layer will not catch it."""
    with patch(
        "bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi",
        side_effect=TimeoutError("timed out"),
    ):
        with pytest.raises(TimeoutError):
            lambda_handler({"queryStringParameters": {"lat": "37.7749", "lon": "-122.4194"}}, None)


def test_rate_limit_exceeded_returns_429():
    with patch(
        "bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi",
        side_effect=RateLimitExceededError("Cache-miss budget exhausted for this window (400 per 3600s)"),
    ):
        response = lambda_handler({"queryStringParameters": {"lat": "37.7749", "lon": "-122.4194"}}, None)

    assert response["statusCode"] == 429
    body = json.loads(response["body"])
    assert "budget" not in body["error"]  # internal implementation detail, not for clients


def test_out_of_coverage_returns_400():
    with patch(
        "bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi",
        side_effect=OutOfCoverageError("Location is outside AirNow's coverage area"),
    ):
        response = lambda_handler({"queryStringParameters": {"lat": "0.0", "lon": "-160.0"}}, None)

    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "coverage" in body["error"]
