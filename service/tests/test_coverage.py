"""Unit tests for coverage-area validation (bluegull-aqi-q9r.30)."""
import pytest

from bluegull_aqi_service.coverage import OutOfCoverageError, validate_coverage

# San Francisco -- well within CONUS.
VALID_LAT, VALID_LON = 37.7749, -122.4194


def test_valid_conus_location_passes():
    validate_coverage(VALID_LAT, VALID_LON)  # must not raise


def test_valid_alaska_location_passes():
    validate_coverage(61.2181, -149.9003)  # Anchorage


def test_valid_hawaii_location_passes():
    validate_coverage(21.3069, -157.8583)  # Honolulu


def test_valid_puerto_rico_location_passes():
    validate_coverage(18.4655, -66.1057)  # San Juan


@pytest.mark.parametrize("lat,lon", [(91.0, -122.0), (-91.0, -122.0)])
def test_latitude_out_of_physical_range_rejected(lat, lon):
    with pytest.raises(OutOfCoverageError, match="Latitude"):
        validate_coverage(lat, lon)


@pytest.mark.parametrize("lat,lon", [(37.0, 181.0), (37.0, -181.0)])
def test_longitude_out_of_physical_range_rejected(lat, lon):
    with pytest.raises(OutOfCoverageError, match="Longitude"):
        validate_coverage(lat, lon)


def test_middle_of_pacific_rejected():
    with pytest.raises(OutOfCoverageError, match="coverage area"):
        validate_coverage(0.0, -160.0)


def test_europe_rejected():
    with pytest.raises(OutOfCoverageError, match="coverage area"):
        validate_coverage(48.8566, 2.3522)  # Paris


def test_antarctica_rejected():
    with pytest.raises(OutOfCoverageError, match="coverage area"):
        validate_coverage(-75.0, 0.0)


def test_error_message_never_echoes_submitted_coordinates():
    try:
        validate_coverage(0.0, -160.0)
    except OutOfCoverageError as exc:
        assert "0.0" not in str(exc)
        assert "160" not in str(exc)
