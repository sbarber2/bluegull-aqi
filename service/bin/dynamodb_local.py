#!/usr/bin/env python3
"""Start/stop DynamoDB Local for local dev and tests.

Deliberately much simpler than Plant-Tracer's bin/local_services.py, which
manages several services (DynamoDB Local, MinIO, Mailpit) generically -- this
project only needs DynamoDB, so a single-purpose script is clearer than a
one-service instance of a multi-service abstraction.

The jar is downloaded on demand (never committed -- see .gitignore) rather
than vendored into the repo as a binary, since nothing else in this project
commits binaries and ~130MB unpacked is a lot of repo weight for something
`make dynamodb-local-setup` can fetch in a few seconds.
"""
import argparse
import os
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8000
DOWNLOAD_URL = "https://s3.us-west-2.amazonaws.com/dynamodb-local/dynamodb_local_latest.tar.gz"

SERVICE_DIR = Path(__file__).resolve().parent.parent
DDB_DIR = SERVICE_DIR / ".dynamodb-local"
JAR_PATH = DDB_DIR / "DynamoDBLocal.jar"
LIB_PATH = DDB_DIR / "DynamoDBLocal_lib"
DATA_DIR = SERVICE_DIR / "var" / "dynamodb-local-data"
LOG_DIR = SERVICE_DIR / "logs"
PID_FILE = SERVICE_DIR / "var" / "dynamodb_local.pid"


def setup() -> None:
    """Download and extract DynamoDB Local if not already present."""
    if JAR_PATH.exists():
        print(f"Already present: {JAR_PATH}")
        return
    DDB_DIR.mkdir(parents=True, exist_ok=True)
    tarball = DDB_DIR / "dynamodb_local_latest.tar.gz"
    print(f"Downloading {DOWNLOAD_URL} ...")
    urllib.request.urlretrieve(DOWNLOAD_URL, tarball)
    print("Extracting ...")
    subprocess.run(["tar", "xzf", str(tarball)], cwd=DDB_DIR, check=True)
    tarball.unlink()
    print(f"Ready: {JAR_PATH}")


def start() -> None:
    """Start DynamoDB Local in the background, writing its PID to PID_FILE."""
    if not JAR_PATH.exists():
        setup()

    if PID_FILE.exists():
        pid = int(PID_FILE.read_text().strip())
        if _is_running(pid):
            print(f"Already running (pid {pid})")
            return
        PID_FILE.unlink()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stdout_log = open(LOG_DIR / "dynamodb_local.stdout", "ab")  # pylint: disable=consider-using-with
    stderr_log = open(LOG_DIR / "dynamodb_local.stderr", "ab")  # pylint: disable=consider-using-with

    process = subprocess.Popen(
        [
            "java",
            f"-Djava.library.path={LIB_PATH}",
            "-jar",
            str(JAR_PATH),
            "-sharedDb",
            "-dbPath",
            str(DATA_DIR),
            "-port",
            str(PORT),
        ],
        stdout=stdout_log,
        stderr=stderr_log,
    )
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(process.pid))

    for _ in range(30):
        if _port_open():
            print(f"DynamoDB Local running on port {PORT} (pid {process.pid})")
            return
        time.sleep(0.5)
    print(f"DynamoDB Local did not become ready in time -- check {LOG_DIR}", file=sys.stderr)
    sys.exit(1)


def stop() -> None:
    """Stop DynamoDB Local if running."""
    if not PID_FILE.exists():
        print("Not running (no pid file)")
        return
    pid = int(PID_FILE.read_text().strip())
    if _is_running(pid):
        os.kill(pid, signal.SIGTERM)
        print(f"Stopped (pid {pid})")
    PID_FILE.unlink()


def _is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _port_open() -> bool:
    import socket  # pylint: disable=import-outside-toplevel

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        return sock.connect_ex((HOST, PORT)) == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["setup", "start", "stop"])
    args = parser.parse_args()
    {"setup": setup, "start": start, "stop": stop}[args.action]()
