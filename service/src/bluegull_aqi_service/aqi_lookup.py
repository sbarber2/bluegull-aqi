"""Core AQI lookup: check cache, fall back to AirNow, cache the result.

Deliberately a plain function, not the Lambda entry point -- see
lambda_handler.py and doc/DESIGN.md "Local development (no AWS required)".
This is what lets the exact same code run under the native local runner,
under pytest against DynamoDB Local, and in Lambda.
"""
import logging
import os
from typing import Optional

import boto3

from bluegull_aqi_service import airnow_client, cache, coverage

logger = logging.getLogger(__name__)

DEFAULT_CACHE_TTL_SECONDS = 3600

_cached_api_key: Optional[str] = None


def get_aqi(latitude: float, longitude: float) -> dict:
    """Return current AQI observations for a location, using the cache first.

    Returns {"observations": [...], "cached": bool} -- "observations" is
    AirNow's own array of per-pollutant readings, unaltered (bluegull-aqi-10h.17).

    Raises coverage.OutOfCoverageError before touching the cache or AirNow at
    all if the location is invalid or outside AirNow's coverage area
    (bluegull-aqi-q9r.30) -- rejecting it here, not just in the cache miss
    path, matters because a cache *hit* check itself has a cost at scale.
    """
    coverage.validate_coverage(latitude, longitude)

    store = cache.Cache()
    key = cache.location_key(latitude, longitude)
    # Never log latitude/longitude, key, or its rounded form directly -- log
    # only the one-way hash (bluegull-aqi-q9r.27).
    location_id = cache.hash_location_key(key)

    hit = store.get(key)
    if hit is not None:
        logger.info("AQI lookup for %s served from cache", location_id)
        return {"observations": hit, "cached": True}

    observations = airnow_client.fetch_current_observations(
        latitude, longitude, _resolve_airnow_api_key()
    )
    ttl_seconds = int(os.environ.get("CACHE_TTL_SECONDS", DEFAULT_CACHE_TTL_SECONDS))
    store.put(key, observations, ttl_seconds)
    logger.info("AQI lookup for %s fetched from AirNow", location_id)
    return {"observations": observations, "cached": False}


def _resolve_airnow_api_key() -> str:
    """Resolve the AirNow API key: env var first (local dev via .env), else
    SSM (production) -- fetched once per cold start and reused across warm
    invocations, per bluegull-aqi-q9r.18's cold-start guidance."""
    global _cached_api_key  # pylint: disable=global-statement
    if _cached_api_key:
        return _cached_api_key

    env_key = os.environ.get("AIRNOW_API_KEY")
    if env_key:
        _cached_api_key = env_key
        return _cached_api_key

    parameter_name = os.environ["AIRNOW_API_KEY_SSM_PARAMETER"]
    ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "us-east-2"))
    response = ssm.get_parameter(Name=parameter_name, WithDecryption=True)
    _cached_api_key = response["Parameter"]["Value"]
    return _cached_api_key
