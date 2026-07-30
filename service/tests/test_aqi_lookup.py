"""Integration test: real DynamoDB Local cache, stubbed AirNow client --
verifies the cache-hit/miss orchestration without hitting the live API."""
import threading
import time
from unittest.mock import patch

import pytest

from bluegull_aqi_service import aqi_lookup, cache
from bluegull_aqi_service.airnow_client import AirNowError
from bluegull_aqi_service.airnow_stub import STUB_LATITUDE, STUB_LONGITUDE
from bluegull_aqi_service.coverage import OutOfCoverageError
from bluegull_aqi_service.rate_limiter import MissRateLimiter, RateLimitExceededError

SAMPLE = [{"parameterName": "PM2.5", "nowcastAQI": 31, "reportingAgency": "Bay Area Air District"}]


def test_get_aqi_cache_miss_then_hit(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    # Chicago -- must be a real North American location: bluegull-aqi-q9r.30
    # now rejects anything outside AirNow's coverage area before this point.
    lat, lon = 41.8781, -87.6298

    # DynamoDB Local persists data across separate pytest runs (by design --
    # see conftest.py), so a prior run may have already cached this location.
    # Clear it first rather than assuming a clean slate.
    cache.Cache().delete(cache.location_key(lat, lon))

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        mock_fetch.return_value = SAMPLE

        result1 = aqi_lookup.get_aqi(lat, lon)
        assert result1 == {"observations": SAMPLE, "cached": False}
        mock_fetch.assert_called_once()

        result2 = aqi_lookup.get_aqi(lat, lon)
        assert result2 == {"observations": SAMPLE, "cached": True}
        mock_fetch.assert_called_once()  # still just once -- second call hit cache


def test_get_aqi_rejects_out_of_coverage_before_touching_cache_or_airnow(monkeypatch):
    """The whole point of bluegull-aqi-q9r.30: a bogus location must be
    rejected before it costs a cache lookup or an AirNow call, not just
    before the AirNow call."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch, patch(
        "bluegull_aqi_service.aqi_lookup.cache.Cache"
    ) as mock_cache_cls:
        with pytest.raises(OutOfCoverageError):
            aqi_lookup.get_aqi(0.0, -160.0)  # middle of the Pacific

        mock_fetch.assert_not_called()
        mock_cache_cls.assert_not_called()


def test_get_aqi_serves_stub_without_calling_airnow_or_needing_a_key(monkeypatch):
    monkeypatch.setenv("AIRNOW_STUB_MODE", "1")
    monkeypatch.delenv("AIRNOW_API_KEY", raising=False)  # must not be needed for the stub path

    cache.Cache().delete(cache.location_key(STUB_LATITUDE, STUB_LONGITUDE))

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        result1 = aqi_lookup.get_aqi(STUB_LATITUDE, STUB_LONGITUDE)
        assert result1["cached"] is False
        assert result1["observations"][0]["reportingAgency"] == "BlueGull AQI (stub)"
        mock_fetch.assert_not_called()

        result2 = aqi_lookup.get_aqi(STUB_LATITUDE, STUB_LONGITUDE)
        assert result2["cached"] is True
        mock_fetch.assert_not_called()


def test_get_aqi_reserved_coordinate_behaves_normally_without_stub_env_var(monkeypatch):
    """Without AIRNOW_STUB_MODE set, the reserved coordinate is just another
    location -- it must still call the real AirNow client."""
    monkeypatch.delenv("AIRNOW_STUB_MODE", raising=False)
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")

    cache.Cache().delete(cache.location_key(STUB_LATITUDE, STUB_LONGITUDE))

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        mock_fetch.return_value = SAMPLE
        result = aqi_lookup.get_aqi(STUB_LATITUDE, STUB_LONGITUDE)
        assert result == {"observations": SAMPLE, "cached": False}
        mock_fetch.assert_called_once()


# --- Stale-while-revalidate + single-flight (bluegull-aqi-q9r.15) ----------
#
# "Another concurrent request" is simulated deterministically by having the
# test itself call store.try_acquire_refresh_lock(key) first, standing in
# for a different in-flight Lambda invocation that got there first -- rather
# than relying on real thread/process races, which would make these tests
# flaky.

STALE_SAMPLE = [{"parameterName": "PM2.5", "nowcastAQI": 10, "reportingAgency": "Stale Reading"}]


def test_get_aqi_refreshes_uncontested_expired_entry(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 33.4484, -112.0740  # Phoenix
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)
    store.put(key, STALE_SAMPLE, ttl_seconds=-1)  # already expired

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        mock_fetch.return_value = SAMPLE
        result = aqi_lookup.get_aqi(lat, lon)

    assert result == {"observations": SAMPLE, "cached": False}
    mock_fetch.assert_called_once()
    assert store.get(key) == SAMPLE  # the refresh was actually cached


def test_get_aqi_serves_stale_when_lock_held_by_another_request(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 39.7392, -104.9903  # Denver
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)
    store.put(key, STALE_SAMPLE, ttl_seconds=-1)  # already expired

    assert store.try_acquire_refresh_lock(key) is True  # "another request" wins first

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        result = aqi_lookup.get_aqi(lat, lon)

    assert result == {"observations": STALE_SAMPLE, "cached": True}
    mock_fetch.assert_not_called()  # the loser must not also call AirNow


def test_get_aqi_falls_back_to_stale_when_refresh_fails(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 29.7604, -95.3698  # Houston
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)
    store.put(key, STALE_SAMPLE, ttl_seconds=-1)  # already expired, but on hand

    with patch(
        "bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations",
        side_effect=AirNowError("upstream failure"),
    ):
        result = aqi_lookup.get_aqi(lat, lon)

    assert result == {"observations": STALE_SAMPLE, "cached": True}


def test_get_aqi_propagates_error_on_refresh_failure_with_no_stale_data(monkeypatch):
    """No stale value to fall back to -- must not swallow the error."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 47.6062, -122.3321  # Seattle
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)  # true cold start -- nothing cached at all

    with patch(
        "bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations",
        side_effect=AirNowError("upstream failure"),
    ):
        with pytest.raises(AirNowError):
            aqi_lookup.get_aqi(lat, lon)


def test_get_aqi_waits_for_concurrent_refresh_on_true_cold_start(monkeypatch):
    """Nothing cached at all, and we lose the single-flight race -- must
    wait for the winner rather than also calling AirNow, per the "may
    block" allowance for this rare, once-per-location case."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    monkeypatch.setattr(aqi_lookup, "COLD_START_WAIT_TIMEOUT_SECONDS", 3)
    monkeypatch.setattr(aqi_lookup, "COLD_START_POLL_INTERVAL_SECONDS", 0.05)

    lat, lon = 25.7617, -80.1918  # Miami
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)

    assert store.try_acquire_refresh_lock(key) is True  # "another request" wins first

    def _winner_finishes_shortly():
        time.sleep(0.2)
        store.put(key, SAMPLE, ttl_seconds=3600)

    winner_thread = threading.Thread(target=_winner_finishes_shortly)
    winner_thread.start()
    try:
        with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
            result = aqi_lookup.get_aqi(lat, lon)
    finally:
        winner_thread.join()

    assert result == {"observations": SAMPLE, "cached": True}
    mock_fetch.assert_not_called()  # resolved by waiting, never fetched directly


def test_get_aqi_falls_back_to_direct_fetch_when_wait_times_out(monkeypatch):
    """The winner never finishes (crashed/stuck) -- after the bounded wait,
    fetch directly rather than leaving the caller with nothing."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    monkeypatch.setattr(aqi_lookup, "COLD_START_WAIT_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(aqi_lookup, "COLD_START_POLL_INTERVAL_SECONDS", 0.05)

    lat, lon = 39.9526, -75.1652  # Philadelphia
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)

    assert store.try_acquire_refresh_lock(key) is True  # held for the whole test -- never released

    with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
        mock_fetch.return_value = SAMPLE
        result = aqi_lookup.get_aqi(lat, lon)

    assert result == {"observations": SAMPLE, "cached": True}
    mock_fetch.assert_called_once()
    assert store.get(key) == SAMPLE  # the fallback fetch was cached too


# --- Cache-miss rate limiting (bluegull-aqi-q9r.32) -------------------------
#
# A global budget, not per-location -- two *different* locations are used
# below specifically to prove that, unlike the single-flight lock, this
# isn't scoped per LocationKey.

RATE_LIMIT_WINDOW_SECONDS = 3600


def _reset_current_miss_window():
    MissRateLimiter().reset_current_window(RATE_LIMIT_WINDOW_SECONDS)


def test_get_aqi_falls_back_to_stale_when_miss_budget_exhausted(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    monkeypatch.setenv("MISS_RATE_LIMIT_WINDOW_SECONDS", str(RATE_LIMIT_WINDOW_SECONDS))
    monkeypatch.setenv("MISS_RATE_LIMIT_BUDGET", "1")
    _reset_current_miss_window()

    lat1, lon1 = 41.8781, -87.6298  # Chicago -- spends the only unit of budget
    lat2, lon2 = 39.7392, -104.9903  # Denver -- distinct location, same global budget
    store = cache.Cache()
    key1, key2 = cache.location_key(lat1, lon1), cache.location_key(lat2, lon2)
    store.delete(key1)
    store.delete(key2)
    store.put(key2, STALE_SAMPLE, ttl_seconds=-1)  # already expired, but on hand

    try:
        with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
            mock_fetch.return_value = SAMPLE
            result1 = aqi_lookup.get_aqi(lat1, lon1)
            assert result1 == {"observations": SAMPLE, "cached": False}

            result2 = aqi_lookup.get_aqi(lat2, lon2)  # budget already exhausted by the call above
            assert result2 == {"observations": STALE_SAMPLE, "cached": True}
            mock_fetch.assert_called_once()  # the second lookup must not reach AirNow at all
    finally:
        _reset_current_miss_window()


def test_get_aqi_propagates_rate_limit_error_with_no_stale_data(monkeypatch):
    """No stale value to fall back to -- must not swallow the error, mirroring
    test_get_aqi_propagates_error_on_refresh_failure_with_no_stale_data above."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    monkeypatch.setenv("MISS_RATE_LIMIT_WINDOW_SECONDS", str(RATE_LIMIT_WINDOW_SECONDS))
    monkeypatch.setenv("MISS_RATE_LIMIT_BUDGET", "1")
    _reset_current_miss_window()

    lat1, lon1 = 47.6062, -122.3321  # Seattle -- spends the only unit of budget
    lat2, lon2 = 25.7617, -80.1918  # Miami -- true cold start, nothing to fall back to
    store = cache.Cache()
    key1, key2 = cache.location_key(lat1, lon1), cache.location_key(lat2, lon2)
    store.delete(key1)
    store.delete(key2)

    try:
        with patch("bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations") as mock_fetch:
            mock_fetch.return_value = SAMPLE
            aqi_lookup.get_aqi(lat1, lon1)

            with pytest.raises(RateLimitExceededError):
                aqi_lookup.get_aqi(lat2, lon2)
            mock_fetch.assert_called_once()
    finally:
        _reset_current_miss_window()


def test_get_aqi_stub_path_never_consumes_miss_budget(monkeypatch):
    """The stub path must not need, or spend, the real budget -- it never
    calls AirNow at all (bluegull-aqi-q9r.20)."""
    monkeypatch.setenv("AIRNOW_STUB_MODE", "1")
    monkeypatch.delenv("AIRNOW_API_KEY", raising=False)
    cache.Cache().delete(cache.location_key(STUB_LATITUDE, STUB_LONGITUDE))

    with patch("bluegull_aqi_service.aqi_lookup._consume_miss_budget") as mock_consume:
        result = aqi_lookup.get_aqi(STUB_LATITUDE, STUB_LONGITUDE)

    assert result["cached"] is False
    mock_consume.assert_not_called()
