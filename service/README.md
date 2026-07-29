# BlueGull AQI service

A rate-limited caching proxy in front of the AirNow API, deployed via AWS SAM.
See [`/doc/DESIGN.md`](../doc/DESIGN.md) for the full design, including the
"no AWS needed to test" local-development requirement and the compliance
obligations that constrain this service's behavior.

**Status**: bare scaffold. The Lambda handler is a placeholder; the cache,
secret storage, rate limiting, and custom domain are separate tracked tasks
(`bd list --label compliance`, `bd dep tree bluegull-aqi-q9r`).

```bash
make install    # poetry install
make pytest     # run tests
make validate   # sam validate --lint
make build      # sam build (generates requirements.txt from poetry first)
```

Deploying requires AWS credentials for account `843088391598` and is not yet
wired up as a Makefile target -- see `bluegull-aqi-q9r.8`.
