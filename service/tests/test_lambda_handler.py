"""Smoke test for the scaffold. Replaced by real handler-contract tests in
bluegull-aqi-q9r.14 once the handler actually does something."""
import json

from bluegull_aqi_service.lambda_handler import lambda_handler


def test_lambda_handler_returns_200():
    """The scaffold handler responds with a 200 and a status field."""
    response = lambda_handler({}, None)
    assert response["statusCode"] == 200
    assert json.loads(response["body"])["status"] == "ok"
