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

**Recommended**: store the key in 1Password rather than as a literal in
`.env` -- put an `op://` reference there instead (see `.env.example`) and
run via:

```bash
op run --env-file=.env -- make run-local
```

`op run` resolves the reference and injects the real value into the
process's environment for its lifetime only; the file on disk never holds
the actual key. A bare `make run-local` (no `op run` prefix) will pass the
literal `op://...` string to AirNow and get a confusing 401 -- the prefix is
what makes the reference resolve.

Deploying requires AWS credentials for account `843088391598`. Manually:

```bash
sam build
sam deploy --config-env dev   # or stage / prod
```

Each stack gets a custom domain under `bluegull.solutions`
(`bluegull-aqi-q9r.6`): `dev.aqi.bluegull.solutions`, `stage.aqi.bluegull.solutions`,
and `aqi.bluegull.solutions` for prod. ACM cert + DNS validation are handled
by CloudFormation itself (`AWS::CertificateManager::Certificate` with
`DomainValidationOptions` pointing at the shared Route53 hosted zone), so a
plain `sam deploy` blocks until the cert is actually issued -- no separate
manual ACM step.

CI/CD deploy (`.github/workflows/deploy.yml-OFF`, `bluegull-aqi-q9r.8`) is
written but disabled until the first manual dev deploy
(`bluegull-aqi-q9r.10`) has happened -- the stack must exist before CI ever
touches it. The OIDC IAM role it assumes (`bluegull-aqi-q9r.29`) is already
live: `arn:aws:iam::843088391598:role/bluegull-aqi-github-deploy`, trust
policy and permissions in `service/iam/`. dev and stage deploy from any
branch/ref; prod deploys ONLY from a `vX.Y.Z` release tag (`gh release
create vX.Y.Z`), enforced both in the workflow and by a GitHub Environment
deployment-tag policy on `prod`.
