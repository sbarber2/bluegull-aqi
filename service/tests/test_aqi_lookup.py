"""Integration test: real DynamoDB Local cache, stubbed AirNow client --
verifies the cache-hit/miss orchestration without hitting the live API."""
from unittest.mock import patch

import pytest

from bluegull_aqi_service import aqi_lookup, cache
from bluegull_aqi_service.airnow_stub import STUB_LATITUDE, STUB_LONGITUDE
from bluegull_aqi_service.coverage import OutOfCoverageError

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
