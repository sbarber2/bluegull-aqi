"""Cache tests run against real DynamoDB Local (see conftest.py), not moto --
matching doc/DESIGN.md's stated preference for higher-fidelity DynamoDB
semantics over a mocked approximation."""
from bluegull_aqi_service.cache import Cache, location_key


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
