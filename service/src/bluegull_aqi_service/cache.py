"""DynamoDB-backed cache for AirNow observations.

The endpoint_url/region come from environment variables so the exact same
code runs against production DynamoDB and against DynamoDB Local for local
dev and tests -- see doc/DESIGN.md "Local development (no AWS required)".

Supports stale-while-revalidate + single-flight (bluegull-aqi-q9r.15):
`get()` is a fresh-hit-only lookup, `get_stale()` returns whatever's cached
regardless of expiry (for serving a slightly-old value immediately instead
of blocking on AirNow), and `try_acquire_refresh_lock()` is a DynamoDB
conditional write that lets exactly one concurrent request win the right to
actually call AirNow and refresh the entry -- see aqi_lookup.py for how
these compose. The orchestration logic itself lives there, not here; this
module only provides the primitives.
"""
import hashlib
import json
import logging
import os
import time
from typing import Optional

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

# Generous relative to AirNow's own 10s request timeout (airnow_client.py) --
# long enough that a normal refresh always finishes well within it, short
# enough that a crashed/stuck winner doesn't block the lock for long. Not a
# SAM Parameter: this is an internal implementation detail, not something an
# operator should need to tune per environment.
REFRESH_LOCK_SECONDS = 20

# Matches the client-side rounding decision (~1km precision, since AirNow
# resolves to the nearest monitoring station regardless) -- see doc/DESIGN.md
# Security & abuse resistance. 2 decimal degrees of latitude is ~1.1km.
LOCATION_KEY_PRECISION = 2


def location_key(latitude: float, longitude: float) -> str:
    """Derive the cache partition key for a location, rounded to a coarse grid."""
    return f"{round(latitude, LOCATION_KEY_PRECISION)},{round(longitude, LOCATION_KEY_PRECISION)}"


def hash_location_key(key: str) -> str:
    """One-way digest of a location key, safe to log (bluegull-aqi-q9r.27).

    Never log location_key -- or raw/rounded coordinates -- directly: even a
    coarse 2-decimal grid cell accumulates an "IP was near location Y at time
    Z" history over a log retention period. This digest still lets separate
    log lines for the same request be correlated without being reversible
    back to a real-world location.
    """
    return hashlib.sha256(key.encode()).hexdigest()[:12]


def resolve_table(table_name: Optional[str] = None):
    """Return the boto3 Table resource for the shared cache table -- reused
    by rate_limiter.py so its own budget counter lives in the same table
    (bluegull-aqi-q9r.32) instead of duplicating this endpoint/region
    resolution logic."""
    table_name = table_name or os.environ["CACHE_TABLE_NAME"]
    client_kwargs = {"region_name": os.environ.get("AWS_REGION", "us-east-2")}
    endpoint_url = os.environ.get("DYNAMODB_ENDPOINT_URL")
    if endpoint_url:
        client_kwargs["endpoint_url"] = endpoint_url
    return boto3.resource("dynamodb", **client_kwargs).Table(table_name)


def seconds_until_next_boundary(ttl_seconds: int, now: Optional[int] = None) -> int:
    """Seconds remaining until the next boundary of size ttl_seconds since
    the Unix epoch -- e.g. with ttl_seconds=3600, always the top of the next
    UTC hour, matching AirNow's roughly-hourly NowCast publish cadence
    (bluegull-aqi-q9r.15), rather than a rolling window that drifts based on
    each entry's own first-request time. All entries sharing a TTL expire on
    the same predictable schedule instead of being staggered arbitrarily.
    """
    now = now if now is not None else int(time.time())
    return ttl_seconds - (now % ttl_seconds)


class Cache:
    """Thin wrapper around a single DynamoDB table used as a TTL cache."""

    def __init__(self, table_name: Optional[str] = None):
        self._table = resolve_table(table_name)

    def get(self, key: str) -> Optional[list]:
        """Return cached data for key, or None on a miss (absent, expired, or
        a lock-only placeholder with no Data yet -- try_acquire_refresh_lock()
        can create an item that's just a lock, on a true cold start). See
        get_stale() to serve an expired value anyway (stale-while-revalidate,
        bluegull-aqi-q9r.15)."""
        item = self._get_item(key)
        if item is None or "ExpiresAt" not in item:
            logger.debug("Cache miss (absent) for %s", hash_location_key(key))
            return None
        if item["ExpiresAt"] < int(time.time()):
            logger.debug("Cache miss (expired) for %s", hash_location_key(key))
            return None
        logger.debug("Cache hit for %s", hash_location_key(key))
        return json.loads(item["Data"])

    def get_stale(self, key: str) -> Optional[list]:
        """Return cached data for key regardless of expiry -- None if the
        item is absent, or is a lock-only placeholder with no Data yet
        (try_acquire_refresh_lock() can create one on a true cold start).
        For stale-while-revalidate (bluegull-aqi-q9r.15): serve a slightly-
        old value immediately rather than blocking every concurrent caller
        on a fresh AirNow call."""
        item = self._get_item(key)
        if item is None or "Data" not in item:
            return None
        return json.loads(item["Data"])

    def _get_item(self, key: str) -> Optional[dict]:
        response = self._table.get_item(Key={"LocationKey": key})
        return response.get("Item")

    def try_acquire_refresh_lock(self, key: str) -> bool:
        """Attempt to become the single-flight winner for refreshing key
        (bluegull-aqi-q9r.15). Returns True if this caller won -- it must
        now actually call AirNow and put() the result -- or False if another
        request already holds the lock, in which case the caller should
        serve a stale value if it has one (get_stale()) rather than also
        calling AirNow.

        A conditional UpdateItem, not a separate lock table: it creates the
        item if absent (covering a true cold start, not just a stale-entry
        refresh) and succeeds only if no lock is held or the previous lock
        has itself expired -- so a crashed/timed-out winner can't wedge a
        location forever.
        """
        now = int(time.time())
        try:
            self._table.update_item(
                Key={"LocationKey": key},
                UpdateExpression="SET RefreshLockExpiresAt = :new_lock",
                ConditionExpression=(
                    "attribute_not_exists(RefreshLockExpiresAt) OR RefreshLockExpiresAt < :now"
                ),
                ExpressionAttributeValues={":new_lock": now + REFRESH_LOCK_SECONDS, ":now": now},
            )
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def delete(self, key: str) -> None:
        """Remove a cache entry, if present. Mainly useful for tests that need
        a guaranteed-clean slate rather than relying on TTL expiry."""
        self._table.delete_item(Key={"LocationKey": key})

    def put(self, key: str, data: list, ttl_seconds: int) -> None:
        """Store data under key with the given TTL.

        Uses UpdateItem, not PutItem: PutItem replaces the *entire* item,
        which would silently clear RefreshLockExpiresAt the instant the
        single-flight winner writes its result (bluegull-aqi-q9r.15) --
        opening a window where a slower concurrent request finds no lock,
        acquires a "fresh" one, and redundantly re-fetches from AirNow right
        after a successful refresh. The lock is instead left to expire on
        its own short schedule, never cleared early.
        """
        now = int(time.time())
        self._table.update_item(
            Key={"LocationKey": key},
            UpdateExpression="SET #data = :data, FetchedAt = :fetched_at, ExpiresAt = :expires_at",
            ExpressionAttributeNames={"#data": "Data"},
            ExpressionAttributeValues={
                ":data": json.dumps(data),
                ":fetched_at": now,
                ":expires_at": now + ttl_seconds,
            },
        )
        logger.debug("Cache put for %s", hash_location_key(key))


def create_table_if_missing(table_name: str, region_name: str, endpoint_url: Optional[str] = None) -> None:
    """Create the cache table for local dev/tests. Never called in production --
    the table there is a CloudFormation resource (bluegull-aqi-q9r.3)."""
    client_kwargs = {"region_name": region_name}
    if endpoint_url:
        client_kwargs["endpoint_url"] = endpoint_url
    client = boto3.client("dynamodb", **client_kwargs)

    existing = client.list_tables().get("TableNames", [])
    if table_name in existing:
        return

    client.create_table(
        TableName=table_name,
        AttributeDefinitions=[{"AttributeName": "LocationKey", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "LocationKey", "KeyType": "HASH"}],
        BillingMode="PAY_PER_REQUEST",
    )
    client.get_waiter("table_exists").wait(TableName=table_name)
    # DynamoDB Local supports TTL configuration but does not enforce expiry
    # itself, so tests check ExpiresAt manually rather than relying on
    # automatic deletion -- see Cache.get().
    client.update_time_to_live(
        TableName=table_name,
        TimeToLiveSpecification={"AttributeName": "ExpiresAt", "Enabled": True},
    )
