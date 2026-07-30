"""Real thread-level concurrency against DynamoDB Local (bluegull-aqi-q9r.16)
-- not a simulated lock. This is deliberately a separate module from
test_aqi_lookup.py's stale-while-revalidate tests, which pre-acquire the
lock in the test's own thread to deterministically exercise the "loser"
code path. That approach can't catch a genuine race condition: it was
exactly a test like the ones below (run manually, live, against the local
runner) that caught bluegull-aqi-q9r.15's original bug -- Cache.put() used
PutItem, which replaces the whole item and silently cleared
RefreshLockExpiresAt the instant the winner wrote its result, letting a
slower concurrent request acquire a "fresh" lock and redundantly re-fetch
from AirNow. A single-threaded test suite would never have caught that.
"""
import threading
import time
from unittest.mock import patch

from bluegull_aqi_service import aqi_lookup, cache

SAMPLE = [{"parameterName": "PM2.5", "nowcastAQI": 31, "reportingAgency": "Bay Area Air District"}]
STALE_SAMPLE = [{"parameterName": "PM2.5", "nowcastAQI": 10, "reportingAgency": "Stale Reading"}]


def _run_concurrently(worker, thread_count: int) -> None:
    threads = [threading.Thread(target=worker) for _ in range(thread_count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


def test_concurrent_cache_misses_produce_exactly_one_airnow_call(monkeypatch):
    """The stampede mitigation's core promise: AirNow must see at most one
    call per location per TTL regardless of client concurrency."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 42.3601, -71.0589  # Boston -- not used by other test modules
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)

    call_count = 0
    call_count_lock = threading.Lock()

    def _slow_fetch(*_args, **_kwargs):
        nonlocal call_count
        with call_count_lock:
            call_count += 1
        time.sleep(0.2)  # widens the race window so threads actually overlap
        return SAMPLE

    results = []
    results_lock = threading.Lock()

    def _worker():
        result = aqi_lookup.get_aqi(lat, lon)
        with results_lock:
            results.append(result)

    with patch(
        "bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations",
        side_effect=_slow_fetch,
    ):
        _run_concurrently(_worker, thread_count=10)

    assert call_count == 1
    assert len(results) == 10
    assert all(result["observations"] == SAMPLE for result in results)


def test_concurrent_requests_on_expired_entry_serve_stale_without_blocking(monkeypatch):
    """An expired entry must be served immediately, not block behind the
    request that's revalidating it -- the whole point of stale-while-
    revalidate, and only observable under genuine concurrency."""
    monkeypatch.setenv("AIRNOW_API_KEY", "test-key")
    lat, lon = 36.1627, -86.7816  # Nashville -- not used by other test modules
    store = cache.Cache()
    key = cache.location_key(lat, lon)
    store.delete(key)
    store.put(key, STALE_SAMPLE, ttl_seconds=-1)  # already expired

    def _slow_fetch(*_args, **_kwargs):
        time.sleep(1.0)  # deliberately much slower than a stale response should take
        return SAMPLE

    durations = []
    durations_lock = threading.Lock()

    def _worker():
        start = time.monotonic()
        aqi_lookup.get_aqi(lat, lon)
        elapsed = time.monotonic() - start
        with durations_lock:
            durations.append(elapsed)

    with patch(
        "bluegull_aqi_service.aqi_lookup.airnow_client.fetch_current_observations",
        side_effect=_slow_fetch,
    ):
        _run_concurrently(_worker, thread_count=5)

    # At least one request (a loser, serving the stale value) must have
    # returned well before the slow winner's full 1s AirNow call finished.
    assert min(durations) < 0.5
