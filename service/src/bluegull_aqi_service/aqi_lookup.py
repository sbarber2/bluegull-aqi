"""Core AQI lookup: stale-while-revalidate + single-flight cache, AirNow
fallback (bluegull-aqi-q9r.15).

Deliberately a plain function, not the Lambda entry point -- see
lambda_handler.py and doc/DESIGN.md "Local development (no AWS required)".
This is what lets the exact same code run under the native local runner,
under pytest against DynamoDB Local, and in Lambda.

Three outcomes on a cache miss, in order of preference:
1. Win the single-flight lock -> fetch from AirNow, cache the result,
   return it fresh. Whoever wins pays the AirNow latency; everyone else
   doesn't have to.
2. Lose the lock but a stale (expired) value is on hand -> serve it
   immediately. The winner refreshes it "in the background" only in the
   sense that this request doesn't wait for that other request's work --
   there's no actual async execution here, just no blocking.
3. Lose the lock AND nothing is cached at all (a true cold start for this
   location -- rare, once-per-location) -> there's nothing to serve
   immediately, so this request waits (bounded) for the winner to finish.
"""
import logging
import os
import time
from typing import Optional

import boto3

from bluegull_aqi_service import airnow_client, airnow_stub, cache, coverage, rate_limiter
from bluegull_aqi_service.airnow_client import AirNowError
from bluegull_aqi_service.rate_limiter import RateLimitExceededError

logger = logging.getLogger(__name__)

DEFAULT_CACHE_TTL_SECONDS = 3600

# Deliberately shorter than cache.REFRESH_LOCK_SECONDS: if the lock is still
# held when this expires, re-attempting to acquire it would just fail again,
# so there's no point waiting longer before falling back to fetching
# directly (accepting an occasional extra AirNow call on a slow/crashed
# winner, rather than leaving the caller with nothing).
COLD_START_WAIT_TIMEOUT_SECONDS = 15
COLD_START_POLL_INTERVAL_SECONDS = 0.3

_cached_api_key: Optional[str] = None


def get_aqi(latitude: float, longitude: float) -> dict:
    """Return current AQI observations for a location.

    Returns {"observations": [...], "cached": bool} -- "observations" is
    AirNow's own array of per-pollutant readings, unaltered (bluegull-aqi-10h.17).
    "cached" is True for both a fresh cache hit and a stale-served response;
    it means "this exact request didn't just call AirNow itself."

    Raises coverage.OutOfCoverageError before touching the cache or AirNow at
    all if the location is invalid or outside AirNow's coverage area
    (bluegull-aqi-q9r.30) -- rejecting it here, not just in the cache miss
    path, matters because a cache *hit* check itself has a cost at scale.

    Raises rate_limiter.RateLimitExceededError if the cache-miss budget for
    the current window is exhausted and no stale value exists to serve
    instead (bluegull-aqi-q9r.32) -- misses, not overall request volume, are
    what cost AirNow quota, so this is checked only on the path that would
    actually call AirNow, not on every request.

    On a cache miss for the reserved synthetic load-test coordinate, with
    AIRNOW_STUB_MODE=1 set, returns canned data instead of calling AirNow --
    see airnow_stub.py (bluegull-aqi-q9r.20). All other requests are
    unaffected regardless of that env var.
    """
    coverage.validate_coverage(latitude, longitude)

    store = cache.Cache()
    key = cache.location_key(latitude, longitude)
    # Never log latitude/longitude, key, or its rounded form directly -- log
    # only the one-way hash (bluegull-aqi-q9r.27).
    location_id = cache.hash_location_key(key)

    fresh = store.get(key)
    if fresh is not None:
        logger.info("AQI lookup for %s served from cache", location_id)
        return {"observations": fresh, "cached": True}

    # AirNow must see at most one call per location per TTL regardless of
    # client concurrency (bluegull-aqi-q9r.15) -- get_stale() before racing
    # for the lock so a loser that has something to serve never has to wait.
    stale = store.get_stale(key)

    if store.try_acquire_refresh_lock(key):
        # Re-check: another request can complete an entire fetch-and-cache
        # cycle in the gap between our initial miss-check above and winning
        # this lock just now -- a real race under genuine concurrency, not
        # merely theoretical (caught live, see doc/DESIGN.md changelog). If
        # so, serve that instead of also calling AirNow ourselves.
        already_refreshed = store.get(key)
        if already_refreshed is not None:
            logger.info(
                "AQI lookup for %s resolved by another request while acquiring the lock", location_id
            )
            return {"observations": already_refreshed, "cached": True}
        return _refresh(store, key, location_id, latitude, longitude, stale=stale)

    if stale is not None:
        logger.info("AQI lookup for %s served stale while another request revalidates", location_id)
        return {"observations": stale, "cached": True}

    # True cold start (nothing to serve) and we lost the race -- this is the
    # "may block" case the design explicitly allows for, since it's a rare,
    # self-limiting once-per-location event.
    observations = _wait_for_concurrent_refresh(store, key, location_id, latitude, longitude)
    return {"observations": observations, "cached": True}


def _refresh(  # pylint: disable=too-many-arguments,too-many-positional-arguments
    store: cache.Cache, key: str, location_id: str, latitude: float, longitude: float, stale: Optional[list]
) -> dict:
    """Called by the single-flight lock winner: fetch fresh data and cache
    it. If AirNow fails and a stale value exists, serve that instead of
    propagating the error -- the lock has its own short expiry
    (cache.REFRESH_LOCK_SECONDS), so the next request just tries again. The
    cache-miss budget (bluegull-aqi-q9r.32) being exhausted gets the same
    stale-first treatment as an AirNow failure -- from the caller's
    perspective both mean "can't reach AirNow right now."
    """
    try:
        observations = _fetch_fresh_observations(latitude, longitude, location_id)
    except AirNowError:
        if stale is not None:
            logger.warning("AirNow refresh failed for %s; serving stale data", location_id)
            return {"observations": stale, "cached": True}
        raise
    except RateLimitExceededError:
        if stale is not None:
            logger.warning("Cache-miss budget exhausted for %s; serving stale data", location_id)
            return {"observations": stale, "cached": True}
        raise

    _cache_fresh_result(store, key, observations)
    return {"observations": observations, "cached": False}


def _wait_for_concurrent_refresh(
    store: cache.Cache, key: str, location_id: str, latitude: float, longitude: float
) -> list:
    """Poll for another in-flight request's result rather than also calling
    AirNow -- bounded so a stuck/slow winner can't hang this request
    forever. Falls back to fetching directly if the wait times out: leaving
    the caller with nothing is worse than an occasional extra AirNow call."""
    deadline = time.monotonic() + COLD_START_WAIT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(COLD_START_POLL_INTERVAL_SECONDS)
        data = store.get(key)
        if data is not None:
            logger.info("AQI lookup for %s resolved after waiting for a concurrent refresh", location_id)
            return data

    logger.warning(
        "AQI lookup for %s timed out waiting for a concurrent refresh; fetching directly", location_id
    )
    observations = _fetch_fresh_observations(latitude, longitude, location_id)
    _cache_fresh_result(store, key, observations)
    return observations


def _fetch_fresh_observations(latitude: float, longitude: float, location_id: str) -> list:
    if airnow_stub.is_stub_request(latitude, longitude):
        # Skips key resolution AND the rate limiter entirely -- a load test
        # shouldn't need a real AirNow key configured, or eat into the real
        # budget, just to exercise the stub path.
        logger.info("AQI lookup for %s served from stub (load test mode)", location_id)
        return airnow_stub.stub_observations()

    _consume_miss_budget(location_id)

    observations = airnow_client.fetch_current_observations(latitude, longitude, _resolve_airnow_api_key())
    logger.info("AQI lookup for %s fetched from AirNow", location_id)
    return observations


def _consume_miss_budget(location_id: str) -> None:
    """Gate the one thing in this module that actually costs AirNow quota
    (bluegull-aqi-q9r.32). Deliberately checked here, not earlier in
    get_aqi(): a request resolved by a cache hit, a stale-serve, or another
    request's in-flight refresh never reaches this line at all, so none of
    those consume budget -- only a call that's actually about to hit AirNow
    does."""
    window_seconds = int(os.environ.get("MISS_RATE_LIMIT_WINDOW_SECONDS", rate_limiter.DEFAULT_WINDOW_SECONDS))
    budget = int(os.environ.get("MISS_RATE_LIMIT_BUDGET", rate_limiter.DEFAULT_BUDGET))
    try:
        rate_limiter.MissRateLimiter().consume(window_seconds=window_seconds, budget=budget)
    except RateLimitExceededError:
        logger.warning("Cache-miss budget exhausted; rejecting AirNow call for %s", location_id)
        raise


def _cache_fresh_result(store: cache.Cache, key: str, observations: list) -> None:
    """Aligns expiry to the next TTL boundary (bluegull-aqi-q9r.15) --
    matching AirNow's roughly-hourly NowCast publish cadence when
    CACHE_TTL_SECONDS is the default 3600 -- rather than a rolling window
    from this particular request's time, so entries expire on a predictable
    schedule instead of being staggered by whenever each was first requested.
    """
    configured_ttl = int(os.environ.get("CACHE_TTL_SECONDS", DEFAULT_CACHE_TTL_SECONDS))
    aligned_ttl = cache.seconds_until_next_boundary(configured_ttl)
    store.put(key, observations, aligned_ttl)


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
