"""Cache tests run against real DynamoDB Local (see conftest.py), not moto --
matching doc/DESIGN.md's stated preference for higher-fidelity DynamoDB
semantics over a mocked approximation."""
import time

from bluegull_aqi_service.cache import Cache, location_key, seconds_until_next_boundary


def test_location_key_rounds_coordinates():
    assert location_key(37.774929, -122.419416) == "37.77,-122.42"


def test_cache_miss_when_absent():
    cache = Cache()
    assert cache.get("nonexistent-key-does-not-exist") is None


def test_cache_put_then_get():
    cache = Cache()
    key = location_key(35.0, -100.0)
    data = [{"parameterName": "PM2.5", "nowcastAQI": 31}]
    cache.put(key, data, ttl_seconds=3600)
    assert cache.get(key) == data


def test_cache_expired_entry_is_a_miss():
    cache = Cache()
    key = location_key(40.0, -70.0)
    cache.put(key, [{"nowcastAQI": 1}], ttl_seconds=-1)
    assert cache.get(key) is None


def test_get_stale_returns_none_when_absent():
    cache = Cache()
    assert cache.get_stale("nonexistent-key-does-not-exist") is None


def test_get_stale_returns_expired_data():
    cache = Cache()
    key = location_key(41.0, -71.0)
    data = [{"nowcastAQI": 1}]
    cache.put(key, data, ttl_seconds=-1)  # already expired
    assert cache.get(key) is None  # get() still treats it as a miss
    assert cache.get_stale(key) == data  # get_stale() serves it anyway


def test_try_acquire_refresh_lock_succeeds_when_uncontested():
    cache = Cache()
    key = location_key(42.0, -72.0)
    cache.delete(key)
    assert cache.try_acquire_refresh_lock(key) is True


def test_try_acquire_refresh_lock_fails_when_already_held():
    cache = Cache()
    key = location_key(43.0, -73.0)
    cache.delete(key)
    assert cache.try_acquire_refresh_lock(key) is True
    assert cache.try_acquire_refresh_lock(key) is False  # still held


def test_try_acquire_refresh_lock_succeeds_once_previous_lock_expired():
    cache = Cache()
    key = location_key(44.0, -74.0)
    cache.delete(key)
    assert cache.try_acquire_refresh_lock(key) is True

    # Simulate the lock having expired (rather than sleeping for real in a
    # unit test) by writing an already-past RefreshLockExpiresAt directly.
    cache._table.update_item(  # pylint: disable=protected-access
        Key={"LocationKey": key},
        UpdateExpression="SET RefreshLockExpiresAt = :past",
        ExpressionAttributeValues={":past": int(time.time()) - 1},
    )
    assert cache.try_acquire_refresh_lock(key) is True


def test_seconds_until_next_boundary_aligns_to_hour_grid():
    # 100 seconds past the epoch, hourly grid -> 3500s until the boundary.
    assert seconds_until_next_boundary(3600, now=100) == 3500


def test_seconds_until_next_boundary_on_exact_boundary_rolls_to_next():
    # Exactly on a boundary must still return a positive value -- never 0,
    # which would mean an entry expires the instant it's created.
    assert seconds_until_next_boundary(3600, now=7200) == 3600
