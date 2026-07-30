"""Canned AirNow response for load testing (bluegull-aqi-q9r.20).

MANDATORY before any load test runs, not an optimization: driving many
concurrent uncached requests at the live AirNow API would burn the
project's quota and plausibly violate its terms of use.

Gated on BOTH an explicit env var AND a reserved, obviously-synthetic
coordinate -- either alone is not enough to serve stub data. This means
even a stage with AIRNOW_STUB_MODE=1 set can't accidentally serve stub data
for a real user's request, and a request to the reserved coordinate on a
stage without the env var set behaves like any other (real) location.

Deliberately NOT a template.yaml environment variable: this stays a runtime
env var the code checks for, set out-of-band only for the duration of an
actual load test run (bluegull-aqi-q9r.21, not this task), so there's no way
for it to be baked into a deployed stack by a stray parameter-override.

Stub observations still flow through the normal cache read/write path in
aqi_lookup.get_aqi() -- only the actual outbound AirNow HTTP call is
replaced -- so a load test still exercises real cache/validation/logging
overhead, just not the upstream call itself.
"""
import os

# Deliberately round and off-grid for any real GPS reading -- see
# doc/DESIGN.md "Backend service" for why this specific pair was chosen.
STUB_LATITUDE = 40.0
STUB_LONGITUDE = -100.0

_STUB_OBSERVATIONS = [
    {
        "dateObserved": "2000-01-01",
        "hourObserved": "00:00",
        "localTimeZone": "CST",
        "reportingAreaName": "BlueGull Load Test",
        "siteID": "000000000",
        "siteName": "Synthetic Test Site",
        "parameterName": "PM2.5",
        "nowcastAQI": 42,
        "aqiCategoryName": "Good",
        "reportingAgency": "BlueGull AQI (stub)",
        "lookupBehavior": "Closest Reading By Pollutant",
        "consideredMonitors": "All",
        "lookupBoundary": "50 Miles",
    },
]


def is_stub_request(latitude: float, longitude: float) -> bool:
    """True only when the env gate is on AND the coordinates are the exact
    reserved synthetic location."""
    if os.environ.get("AIRNOW_STUB_MODE") != "1":
        return False
    return latitude == STUB_LATITUDE and longitude == STUB_LONGITUDE


def stub_observations() -> list[dict]:
    """A fresh copy each call -- callers may mutate their own result."""
    return [dict(entry) for entry in _STUB_OBSERVATIONS]
