#!/usr/bin/env python3
"""Local, AWS-free proxy for Lambda cold start (bluegull-aqi-q9r.25).

Import time and deployment package size are both measurable without any
deployment and correlate well with Init Duration. Gating them in ordinary
CI catches the most common cold-start regression -- someone adding a heavy
dependency -- on every PR, long before the nightly perf run
(bluegull-aqi-q9r.24, still open) against a real deployed Lambda ever would.

Ceilings below are deliberately generous placeholders picked with headroom
over locally-measured baselines, not tuned targets -- re-tighten them once
real Init Duration measurements exist (bluegull-aqi-q9r.26). Override via
env vars for local experimentation without editing this file:
MAX_IMPORT_TIME_MS, MAX_PACKAGE_SIZE_MB.
"""
import os
import subprocess
import sys
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent.parent
SRC_DIR = SERVICE_DIR / "src"
BUILD_DIR = SERVICE_DIR / ".aws-sam" / "build" / "AqiFunction"

# ~90ms measured locally for `import bluegull_aqi_service.lambda_handler`
# (dominated by boto3, see doc/DESIGN.md changelog for bluegull-aqi-q9r.18)
# -- generous headroom over that for CI runner variance.
DEFAULT_MAX_IMPORT_TIME_MS = 350.0

# ~21MB measured locally via `make build`, mostly boto3/botocore and their
# transitive deps (deliberately kept vendored -- see bluegull-aqi-q9r.18).
DEFAULT_MAX_PACKAGE_SIZE_MB = 50.0


def measure_import_time_ms() -> float:
    """Import time in a fresh subprocess -- a warm interpreter's import
    cache would hide the real cost, and Lambda's Init always starts cold."""
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import time\n"
            "start = time.perf_counter()\n"
            "import bluegull_aqi_service.lambda_handler\n"
            "print(time.perf_counter() - start)\n",
        ],
        cwd=SRC_DIR,
        capture_output=True,
        text=True,
        check=True,
    )
    return float(result.stdout.strip()) * 1000


def measure_package_size_mb() -> float:
    if not BUILD_DIR.exists():
        raise SystemExit(f"{BUILD_DIR} does not exist -- run `make build` before this gate.")
    total_bytes = sum(f.stat().st_size for f in BUILD_DIR.rglob("*") if f.is_file())
    return total_bytes / (1024 * 1024)


def main() -> int:
    max_import_ms = float(os.environ.get("MAX_IMPORT_TIME_MS", DEFAULT_MAX_IMPORT_TIME_MS))
    max_package_mb = float(os.environ.get("MAX_PACKAGE_SIZE_MB", DEFAULT_MAX_PACKAGE_SIZE_MB))

    import_ms = measure_import_time_ms()
    package_mb = measure_package_size_mb()

    print(f"Import time:  {import_ms:7.1f} ms  (ceiling {max_import_ms:.0f} ms)")
    print(f"Package size: {package_mb:7.1f} MB  (ceiling {max_package_mb:.0f} MB)")

    failed = False
    if import_ms > max_import_ms:
        print(f"FAIL: import time {import_ms:.1f} ms exceeds ceiling {max_import_ms:.0f} ms", file=sys.stderr)
        failed = True
    if package_mb > max_package_mb:
        print(f"FAIL: package size {package_mb:.1f} MB exceeds ceiling {max_package_mb:.0f} MB", file=sys.stderr)
        failed = True

    if failed:
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
