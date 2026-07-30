"""Contract tests: feed lambda_handler realistic, full-shaped API Gateway
HTTP API (payload format 2.0) events -- not the hand-built minimal dicts
test_lambda_handler.py uses -- so the thin-handler-over-core-logic split is
actually verified against what API Gateway really sends, not just
structurally. Fixture shape verified against AWS's own documented example
(https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html),
bluegull-aqi-q9r.14."""
import json
from pathlib import Path
from unittest.mock import patch

from bluegull_aqi_service.lambda_handler import lambda_handler

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text())


def test_real_shaped_event_with_query_params_returns_200():
    event = _load_fixture("api_gateway_event.json")

    with patch("bluegull_aqi_service.lambda_handler.aqi_lookup.get_aqi") as mock_get_aqi:
        mock_get_aqi.return_value = {"observations": [{"nowcastAQI": 31}], "cached": False}
        response = lambda_handler(event, None)

    assert response["statusCode"] == 200
    assert response["headers"]["Content-Type"] == "application/json"
    body = json.loads(response["body"])
    assert body["observations"][0]["nowcastAQI"] == 31
    mock_get_aqi.assert_called_once_with(37.7749, -122.4194)


def test_real_shaped_event_missing_query_params_returns_400():
    """API Gateway v2 omits queryStringParameters entirely (no empty dict)
    when a request has no query string at all -- this fixture matches that
    real shape, not an idealized one."""
    event = _load_fixture("api_gateway_event_missing_params.json")
    assert "queryStringParameters" not in event  # confirms the fixture is realistic

    response = lambda_handler(event, None)

    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "lat" in body["error"] and "lon" in body["error"]
