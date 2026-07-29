"""Test fixtures: DynamoDB Local (real, not moto -- see doc/DESIGN.md Testing
strategy) started once per session, plus per-test isolation for module-level
caches that are otherwise deliberately reused across warm Lambda invocations."""
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))

import dynamodb_local  # noqa: E402  pylint: disable=wrong-import-position,import-error

from bluegull_aqi_service import aqi_lookup, cache  # noqa: E402  pylint: disable=wrong-import-position

TEST_TABLE_NAME = "bluegull-aqi-cache-test"
DYNAMODB_ENDPOINT_URL = "http://localhost:8000"
TEST_REGION = "us-east-2"


@pytest.fixture(scope="session", autouse=True)
def _dynamodb_local():
    os.environ["AWS_REGION"] = TEST_REGION
    os.environ["DYNAMODB_ENDPOINT_URL"] = DYNAMODB_ENDPOINT_URL
    os.environ["CACHE_TABLE_NAME"] = TEST_TABLE_NAME
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "local")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "local")

    dynamodb_local.start()
    cache.create_table_if_missing(TEST_TABLE_NAME, TEST_REGION, DYNAMODB_ENDPOINT_URL)
    yield


@pytest.fixture(autouse=True)
def _reset_cached_api_key():
    """aqi_lookup caches the resolved AirNow key at module scope by design
    (reused across warm Lambda invocations) -- reset it between tests so one
    test's monkeypatched env var can't leak into the next."""
    aqi_lookup._cached_api_key = None  # pylint: disable=protected-access
    yield
    aqi_lookup._cached_api_key = None  # pylint: disable=protected-access
