# BlueGull AQI service

A rate-limited caching proxy in front of the AirNow API, deployed via AWS SAM.
See [`/doc/DESIGN.md`](../doc/DESIGN.md) for the full design, including the
"no AWS needed to test" local-development requirement and the compliance
obligations that constrain this service's behavior.

**Status**: the `GET /aqi?lat=&lon=` lookup works end-to-end -- checks a
DynamoDB cache, falls back to AirNow's `current/ziplatlong` endpoint on a
miss, caches the result. Not yet done: rate limiting, the custom domain, and
the stronger cache behavior under concurrency (`bd list --label compliance`,
`bd dep tree bluegull-aqi-q9r`).

```bash
make install    # poetry install
make pytest     # run tests (auto-starts DynamoDB Local, real not mocked)
make validate   # sam validate --lint
make build      # sam build (generates requirements.txt from poetry first)
```

## Running locally, with no AWS account and no Docker

```bash
cp .env.example .env   # then fill in a real AIRNOW_API_KEY
make run-local
curl "http://localhost:8080/aqi?lat=37.7749&lon=-122.4194"
```

`make run-local` starts DynamoDB Local itself (downloaded on first use --
`make dynamodb-local-setup` to do that step alone) and serves the exact same
`lambda_handler` code over plain HTTP. Deliberately not `sam local
start-api`, which needs Docker and is slower to iterate on -- see
doc/DESIGN.md.

Deploying requires AWS credentials for account `843088391598` and is not yet
wired up as a Makefile target -- see `bluegull-aqi-q9r.8`.
