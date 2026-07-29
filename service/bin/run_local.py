#!/usr/bin/env python3
"""Run the proxy server locally with no AWS deployment and no Docker.

Serves the exact same lambda_handler code over plain HTTP, translating each
request into the API Gateway HTTP API v2 event shape Lambda would receive.
See doc/DESIGN.md "Local development (no AWS required)": deliberately not
`sam local start-api`, which needs Docker and is slower to iterate on.

Usage:
    make run-local
    curl "http://localhost:8080/aqi?lat=37.7749&lon=-122.4194"
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SERVICE_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVICE_DIR / "src"))
sys.path.insert(0, str(SERVICE_DIR / "bin"))

PORT = 8080
LOCAL_CACHE_TABLE_NAME = "bluegull-aqi-cache-local"
LOCAL_DYNAMODB_ENDPOINT_URL = "http://localhost:8000"
LOCAL_REGION = "us-east-2"


def _load_dotenv(path: Path) -> None:
    """Minimal .env loader -- no new dependency for something this small.
    Real exported env vars still win (setdefault), matching normal dotenv
    semantics."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


_load_dotenv(SERVICE_DIR / ".env")

# Local-dev defaults so `make run-local` needs no manual env setup beyond a
# real AIRNOW_API_KEY somewhere (.env or already exported) -- see
# doc/DESIGN.md "Local development (no AWS required)".
os.environ.setdefault("CACHE_TABLE_NAME", LOCAL_CACHE_TABLE_NAME)
os.environ.setdefault("DYNAMODB_ENDPOINT_URL", LOCAL_DYNAMODB_ENDPOINT_URL)
os.environ.setdefault("AWS_REGION", LOCAL_REGION)
os.environ.setdefault("AWS_ACCESS_KEY_ID", "local")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "local")

if not os.environ.get("AIRNOW_API_KEY"):
    print(
        "AIRNOW_API_KEY is not set. Copy .env.example to .env and fill in your "
        "AirNow key, or export it directly.",
        file=sys.stderr,
    )
    sys.exit(1)

import dynamodb_local  # noqa: E402  pylint: disable=wrong-import-position,import-error
from bluegull_aqi_service import cache  # noqa: E402  pylint: disable=wrong-import-position
from bluegull_aqi_service.lambda_handler import lambda_handler  # noqa: E402  pylint: disable=wrong-import-position

dynamodb_local.start()
cache.create_table_if_missing(LOCAL_CACHE_TABLE_NAME, LOCAL_REGION, LOCAL_DYNAMODB_ENDPOINT_URL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # pylint: disable=invalid-name
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}

        event = {
            "version": "2.0",
            "rawPath": parsed.path,
            "queryStringParameters": query or None,
            "requestContext": {"http": {"method": "GET", "path": parsed.path}},
        }
        response = lambda_handler(event, None)

        self.send_response(response["statusCode"])
        for key, value in response.get("headers", {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(response["body"].encode())

    def log_message(self, format, *args):  # pylint: disable=redefined-builtin
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Serving on http://127.0.0.1:{PORT} (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(json.dumps({"status": "stopped"}))
