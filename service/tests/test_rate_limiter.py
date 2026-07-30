"""Real DynamoDB Local -- see doc/DESIGN.md "Testing strategy". Windows are
made deterministic by monkeypatching rate_limiter.time.time() rather than
waiting on the real wall clock or picking a tiny real window (which would be
flaky near a boundary)."""
import threading

import pytest

from bluegull_aqi_service.rate_limiter import DEFAULT_WINDOW_SECONDS, MissRateLimiter, RateLimitExceededError

WINDOW_SECONDS = 3600
# An arbitrary, fixed instant safely inside one window -- not near a boundary.
FIXED_NOW = 10_000_000 + 100


@pytest.fixture(autouse=True)
def _fixed_clock(monkeypatch):
    monkeypatch.setattr("bluegull_aqi_service.rate_limiter.time.time", lambda: FIXED_NOW)
    limiter = MissRateLimiter()
    limiter.reset_current_window(WINDOW_SECONDS)
    yield
    limiter.reset_current_window(WINDOW_SECONDS)


def test_consume_succeeds_while_under_budget():
    limiter = MissRateLimiter()
    for _ in range(3):
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)


def test_consume_raises_once_budget_is_exhausted():
    limiter = MissRateLimiter()
    for _ in range(3):
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)

    with pytest.raises(RateLimitExceededError):
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)


def test_different_windows_have_independent_budgets(monkeypatch):
    limiter = MissRateLimiter()
    for _ in range(3):
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)
    with pytest.raises(RateLimitExceededError):
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)

    # A later instant, one full window on -- must not be affected by the
    # previous window's exhausted budget. Reset first: DynamoDB Local
    # persists data across separate pytest runs (see conftest.py), so a
    # prior run may have already touched this window key too.
    monkeypatch.setattr("bluegull_aqi_service.rate_limiter.time.time", lambda: FIXED_NOW + WINDOW_SECONDS)
    limiter.reset_current_window(WINDOW_SECONDS)
    try:
        limiter.consume(window_seconds=WINDOW_SECONDS, budget=3)
    finally:
        limiter.reset_current_window(WINDOW_SECONDS)


def test_consume_is_atomic_under_concurrent_requests():
    """The whole point of a conditional UpdateItem instead of read-then-write
    (bluegull-aqi-q9r.32): racing requests must not jointly overshoot the
    budget by each observing "still under budget" before any of them writes."""
    limiter = MissRateLimiter()
    budget = 5
    attempts = 20
    successes = []
    lock = threading.Lock()

    def _attempt():
        try:
            limiter.consume(window_seconds=WINDOW_SECONDS, budget=budget)
        except RateLimitExceededError:
            return
        with lock:
            successes.append(1)

    threads = [threading.Thread(target=_attempt) for _ in range(attempts)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(successes) == budget


def test_default_window_matches_airnows_hourly_enforcement_window():
    assert DEFAULT_WINDOW_SECONDS == 3600
