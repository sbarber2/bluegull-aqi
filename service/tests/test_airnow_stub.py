"""Unit tests for the load-test stub gate (bluegull-aqi-q9r.20)."""
from bluegull_aqi_service.airnow_stub import STUB_LATITUDE, STUB_LONGITUDE, is_stub_request, stub_observations

REAL_LAT, REAL_LON = 37.7749, -122.4194


def test_disabled_by_default_even_at_reserved_coordinate(monkeypatch):
    monkeypatch.delenv("AIRNOW_STUB_MODE", raising=False)
    assert is_stub_request(STUB_LATITUDE, STUB_LONGITUDE) is False


def test_env_var_alone_is_not_enough(monkeypatch):
    """A real user's request must never get stubbed just because a stage
    happens to have AIRNOW_STUB_MODE=1 set."""
    monkeypatch.setenv("AIRNOW_STUB_MODE", "1")
    assert is_stub_request(REAL_LAT, REAL_LON) is False


def test_reserved_coordinate_alone_is_not_enough(monkeypatch):
    monkeypatch.delenv("AIRNOW_STUB_MODE", raising=False)
    assert is_stub_request(STUB_LATITUDE, STUB_LONGITUDE) is False


def test_both_env_var_and_reserved_coordinate_enables_stub(monkeypatch):
    monkeypatch.setenv("AIRNOW_STUB_MODE", "1")
    assert is_stub_request(STUB_LATITUDE, STUB_LONGITUDE) is True


def test_stub_observations_returns_independent_copies():
    first = stub_observations()
    first[0]["nowcastAQI"] = 999
    second = stub_observations()
    assert second[0]["nowcastAQI"] != 999
