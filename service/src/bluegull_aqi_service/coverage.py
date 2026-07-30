"""AirNow coverage-area validation (bluegull-aqi-q9r.30).

Rejects coordinates before any cache lookup or upstream AirNow call. Stale-
while-revalidate + single-flight (bluegull-aqi-q9r.15) only collapses
concurrent requests for the *same* cache key -- it does nothing against an
attacker cycling through distinct out-of-range or out-of-coverage
coordinates, each a fresh cache miss that burns the AirNow quota (risking the
key getting banned), fills DynamoDB with junk, and runs up Lambda cost.

The coverage box below is a deliberately generous bounding box for North
America (AirNow's documented coverage: the US, Canada, and Mexico -- see
doc/DESIGN.md "Backend service"), not a precise polygon. A location inside
the box but without a nearby monitor still gets a normal, cheap AirNow
response (empty/no data) -- not an error. The box only needs to catch
obviously bogus locations (the middle of the Pacific, another continent)
before they ever reach the cache or AirNow.
"""

MIN_LATITUDE = -90.0
MAX_LATITUDE = 90.0
MIN_LONGITUDE = -180.0
MAX_LONGITUDE = 180.0

# Covers CONUS, Alaska, Hawaii, Puerto Rico, Canada, and Mexico.
COVERAGE_MIN_LATITUDE = 14.0
COVERAGE_MAX_LATITUDE = 72.0
COVERAGE_MIN_LONGITUDE = -170.0
COVERAGE_MAX_LONGITUDE = -52.0


class OutOfCoverageError(ValueError):
    """Coordinates are not physically valid, or fall outside AirNow's coverage area."""


def validate_coverage(latitude: float, longitude: float) -> None:
    """Raise OutOfCoverageError unless (latitude, longitude) is a physically
    valid coordinate within AirNow's coverage area. Never includes the
    submitted values in the message -- see bluegull-aqi-q9r.27."""
    if not MIN_LATITUDE <= latitude <= MAX_LATITUDE:
        raise OutOfCoverageError(f"Latitude must be between {MIN_LATITUDE} and {MAX_LATITUDE}")
    if not MIN_LONGITUDE <= longitude <= MAX_LONGITUDE:
        raise OutOfCoverageError(f"Longitude must be between {MIN_LONGITUDE} and {MAX_LONGITUDE}")
    if not (
        COVERAGE_MIN_LATITUDE <= latitude <= COVERAGE_MAX_LATITUDE
        and COVERAGE_MIN_LONGITUDE <= longitude <= COVERAGE_MAX_LONGITUDE
    ):
        raise OutOfCoverageError("Location is outside AirNow's coverage area")
