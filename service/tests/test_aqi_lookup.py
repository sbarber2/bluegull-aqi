"""Integration test: real DynamoDB Local cache, stubbed AirNow client --
verifies the cache-hit/miss orchestration without hitting the live API."""
from unittest.mock import patch

from bluegull_aqi_service import aqi_lookup, cache

SAMPLE = [{"parameterName": "PM2.5", "nowcastAQI": 31, "reportingAgency": "Bay Area Air District"}]


def test_get_aqi_cache_miss_then_hit(monkeypatch):
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 51.5074, -0.1278

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
