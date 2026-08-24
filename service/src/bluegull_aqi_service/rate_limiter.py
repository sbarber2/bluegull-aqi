"""Global rate limiter for cache-miss-triggered AirNow calls
(bluegull-aqi-q9r.32).

Builds on the cheaper first line of defense against the cache-cardinality
attack (doc/DESIGN.md "Cache-cardinality attack"): coordinate validation
(bluegull-aqi-q9r.30) and grid-snapping (cache.LOCATION_KEY_PRECISION) bound
*where* an attacker can force a miss. This bounds *how many* of those misses
actually reach AirNow -- the stronger, more targeted defense, since misses
(not overall request volume) are what cost AirNow quota and risk the key
getting blocked, per AirNow's FAQ, "for the rest of the hour" on violation.

A single global budget, not per-location or per-IP: AirNow enforces its own
limit per service key, not per caller, so that's the dimension that actually
matters here. WAF (bluegull-aqi-q9r.5, per-IP) and this module protect
different things and are meant to layer, not substitute for each other.
"""
import time
from typing import Optional

from botocore.exceptions import ClientError

from bluegull_aqi_service.cache import resolve_table

# Matches AirNow's own enforcement window (its FAQ describes a key being
# blocked "for the rest of the hour" on violation) -- self-throttling on the
# same cadence means we back off before AirNow ever has to.
DEFAULT_WINDOW_SECONDS = 3600

# 80% of AirNow's confirmed real limit for this endpoint (500/hour, per
# docs.airnowapi.org/CurrentObservationsByLatLon/docs -- see doc/DESIGN.md
# "Rate limit -- confirmed 2026-08-24"), kept as deliberate headroom rather
# than set to the exact ceiling. This default is only what applies with no
# override -- dev and prod share one AirNow key (same SSM parameter) and so
# share that 500/hour ceiling, and each gets its own smaller split via
# MISS_RATE_LIMIT_BUDGET in service/samconfig.toml (150 dev / 350 prod) so
# they can't combine past it.
DEFAULT_BUDGET = 400

# Distinct from location_key()'s "lat,lon" shape (cache.py) so a budget
# item can never collide with a real cache entry in the shared table.
_WINDOW_KEY_PREFIX = "__miss_budget__:"


class RateLimitExceededError(Exception):
    """Raised when the cache-miss budget for the current window is exhausted."""


class MissRateLimiter:
    """Tracks AirNow-call-triggering cache misses in a fixed wall-clock
    window, shared across every location and caller.

    Reuses Cache's own DynamoDB table rather than a second table -- a
    second on-demand table would double the billing surface here for no
    real benefit at this scale.
    """

    def __init__(self, table_name: Optional[str] = None):
        self._table = resolve_table(table_name)

    def consume(self, window_seconds: int = DEFAULT_WINDOW_SECONDS, budget: int = DEFAULT_BUDGET) -> None:
        """Consume one unit of the current window's budget.

        Raises RateLimitExceededError if the window is already exhausted --
        the caller must not proceed to an actual AirNow call in that case.

        A single conditional UpdateItem, not a read-then-write: atomic under
        concurrency the same way Cache.try_acquire_refresh_lock() is, so
        racing requests can't all observe "budget available" and jointly
        overshoot it.
        """
        window_id = int(time.time()) // window_seconds
        key = f"{_WINDOW_KEY_PREFIX}{window_id}"
        expires_at = (window_id + 1) * window_seconds
        try:
            self._table.update_item(
                Key={"LocationKey": key},
                UpdateExpression="SET ExpiresAt = :expires_at ADD MissCount :one",
                ConditionExpression="attribute_not_exists(MissCount) OR MissCount < :budget",
                ExpressionAttributeValues={":one": 1, ":budget": budget, ":expires_at": expires_at},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise RateLimitExceededError(
                    f"Cache-miss budget exhausted for this window ({budget} per {window_seconds}s)"
                ) from exc
            raise

    def reset_current_window(self, window_seconds: int = DEFAULT_WINDOW_SECONDS) -> None:
        """Delete the current window's counter. Test-only -- production
        relies on the window rolling over and the DynamoDB TTL sweep, never
        an explicit reset."""
        window_id = int(time.time()) // window_seconds
        self._table.delete_item(Key={"LocationKey": f"{_WINDOW_KEY_PREFIX}{window_id}"})
