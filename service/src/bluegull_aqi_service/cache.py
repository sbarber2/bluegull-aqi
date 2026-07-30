"""DynamoDB-backed cache for AirNow observations.

The endpoint_url/region come from environment variables so the exact same
code runs against production DynamoDB and against DynamoDB Local for local
dev and tests -- see doc/DESIGN.md "Local development (no AWS required)".

This is a plain get-or-miss cache: an expired entry is a miss, and a miss
means the caller goes to AirNow. Serving a stale entry while refreshing in
the background, and collapsing concurrent misses on the same key into one
upstream call, is bluegull-aqi-q9r.15 (stale-while-revalidate +
single-flight) -- a deliberate later layer on top of this, not this module's
job.
"""
import hashlib
import json
import logging
import os
import time
from typing import Optional

import boto3

logger = logging.getLogger(__name__)

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


class Cache:
    """Thin wrapper around a single DynamoDB table used as a TTL cache."""

    def __init__(self, table_name: Optional[str] = None):
        self._table_name = table_name or os.environ["CACHE_TABLE_NAME"]
        client_kwargs = {"region_name": os.environ.get("AWS_REGION", "us-east-2")}
        endpoint_url = os.environ.get("DYNAMODB_ENDPOINT_URL")
        if endpoint_url:
            client_kwargs["endpoint_url"] = endpoint_url
        self._resource = boto3.resource("dynamodb", **client_kwargs)
        self._table = self._resource.Table(self._table_name)

    def get(self, key: str) -> Optional[list]:
        """Return cached data for key, or None on a miss (absent or expired)."""
        response = self._table.get_item(Key={"LocationKey": key})
        item = response.get("Item")
        if item is None:
            logger.debug("Cache miss (absent) for %s", hash_location_key(key))
            return None
        if item["ExpiresAt"] < int(time.time()):
            logger.debug("Cache miss (expired) for %s", hash_location_key(key))
            return None
        logger.debug("Cache hit for %s", hash_location_key(key))
        return json.loads(item["Data"])

    def delete(self, key: str) -> None:
        """Remove a cache entry, if present. Mainly useful for tests that need
        a guaranteed-clean slate rather than relying on TTL expiry."""
        self._table.delete_item(Key={"LocationKey": key})

    def put(self, key: str, data: list, ttl_seconds: int) -> None:
        """Store data under key with the given TTL."""
        now = int(time.time())
        self._table.put_item(
            Item={
                "LocationKey": key,
                "Data": json.dumps(data),
                "FetchedAt": now,
                "ExpiresAt": now + ttl_seconds,
            }
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
