"""Lambda entry point.

Deliberately thin: this module only translates between the API Gateway HTTP
API event shape and plain Python calls. The actual lookup/cache logic lives
in aqi_lookup.py so the same code path can run locally against DynamoDB
Local as runs in Lambda against DynamoDB, and so it can be exercised by
contract tests without going through a Lambda event at all. See
doc/DESIGN.md "Local development (no AWS required)".

Basic parameter presence/type checking only. Rejecting coordinates outside
AirNow's coverage area, and rounding/grid-snapping the cache key against a
cardinality attack, is bluegull-aqi-q9r.30 -- a deliberate later layer, not
this module's job.
"""
import json
import logging
import os

from bluegull_aqi_service import aqi_lookup
from bluegull_aqi_service.airnow_client import AirNowError

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)


def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}

    try:
        latitude, longitude = _parse_coordinates(params)
    except ValueError as exc:
        return _response(400, {"error": str(exc)})

    try:
        result = aqi_lookup.get_aqi(latitude, longitude)
    except AirNowError:
        # Never echo AirNow's raw message/URL back to the client or into logs
        # verbatim -- see bluegull-aqi-q9r.27 for the fuller redaction pass.
        # This is deliberately generic already, not a stopgap.
        logger.error("AirNow lookup failed for a request")
        return _response(502, {"error": "Upstream air quality data unavailable"})

    return _response(200, result)


def _parse_coordinates(params: dict) -> tuple[float, float]:
    if "lat" not in params or "lon" not in params:
        raise ValueError("Both 'lat' and 'lon' query parameters are required")
    try:
        latitude = float(params["lat"])
        longitude = float(params["lon"])
    except (TypeError, ValueError) as exc:
        raise ValueError("'lat' and 'lon' must be numeric") from exc
    return latitude, longitude


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
