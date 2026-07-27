# BlueGull AQI — Design

Status: **draft, pre-implementation**. This file is the living design document for the
project; update it as decisions change instead of letting the chat history be the
source of truth.

## Goal

A macOS widget (and companion menu bar app) that displays current Air Quality Index
(AQI) based on the US EPA AirNow API (airnowapi.org), using the Mac's location. Data
can come from either:

- **Direct mode** — the client calls AirNow directly with a user-supplied API key.
- **Service mode** — the client calls a rate-limited BlueGull web service (AWS Lambda
  via SAM), which calls AirNow on the client's behalf using a project-owned key.

The backend is deployed in a similar manner to the Plant-Tracer webapp
(`/Users/sbarber/git/Plant-Tracer/webapp`,
[github.com/Plant-Tracer/webapp](https://github.com/Plant-Tracer/webapp)): AWS SAM,
GitHub Actions CI/CD, Route53/ACM custom domain.

## Decisions made so far

| Topic | Decision |
|---|---|
| AirNow auth (direct mode) | User supplies their own AirNow API key; stored in iCloud Keychain, so it syncs across the user's Macs under their Apple ID. Not bundled in the app binary. |
| Widget type | Both: a WidgetKit desktop widget (macOS 14+) **and** a menu bar app, sharing one core library. |
| Distribution | Mac App Store. Apple Developer Program membership already active. |
| Web service client auth / rate limiting | Anonymous / IP-based (via AWS WAF rate-based rule on the API Gateway). No per-install keys, no login. |
| Menu bar app data scope | Current overall AQI only. |
| Widget data scope | Current AQI **and** full per-pollutant breakdown (PM2.5, PM10, ozone, etc.). |
| Location scope | Current location (CoreLocation) **and** user-pinned locations (zip/address, geocoded locally via `CLGeocoder`/MapKit — no backend geocoding endpoint needed). |
| Refresh cadence | Hourly, matching AirNow's own publish cadence. |
| Minimum macOS version | macOS 14 (Sonoma) — required for desktop WidgetKit widgets anyway. |
| Backend custom domain | Yes, custom domain via Route53 + ACM (domain name: **TBD**, see Open Questions). |
| AWS account | Existing AWS account will be used (same pattern as Plant-Tracer or a separate account — TBD which). AirNow API key for the service **not yet registered**. |
| Apple Developer account | Already enrolled; bundle IDs / App Group still need to be created. |

## Architecture

### Repo layout

```
bluegull-aqi/
  mac-app/                 # Xcode project
    BluegullAQI.xcodeproj
    BluegullAQI/            # container app target (menu bar, MenuBarExtra)
    BluegullAQIWidget/       # WidgetKit extension target
    BluegullAQIKit/          # Swift package shared by both targets
    BluegullAQITests/
  service/                  # AWS SAM backend
    template.yaml
    samconfig.toml
    src/
    tests/
  docs/
    DESIGN.md               # this file
  .github/workflows/
```

### `BluegullAQIKit` (shared Swift package)

Used by both the menu bar app and the widget extension so neither target duplicates
logic and both agree on the same models regardless of data source:

- **Models** — `AQIReading`, `PollutantReading`, `Location`.
- **`AirNowDirectClient`** — calls AirNow's `currentobservation/latLong` (and
  `forecast/latLong` later if forecast is added) using the Keychain-stored key.
- **`BluegullServiceClient`** — calls the BlueGull Lambda endpoint; same response
  shape as the direct client so callers don't care which source answered.
- **`LocationResolver`** — wraps CoreLocation for "current location," and resolves
  pinned locations via `CLGeocoder`.
- **Keychain helper** — reads/writes the AirNow API key (iCloud-synced Keychain item).
- **Cache** — App Group shared container, 1-hour TTL, keyed by location. This is what
  the widget's timeline provider reads; the container app is what writes to it after a
  successful fetch.

### Menu bar app (container app)

- `MenuBarExtra`-based, shows current overall AQI as text/icon.
- Owns: location permission flow, settings UI (data-source mode toggle, AirNow key
  entry, pinned-locations list management), and the actual network fetch (WidgetKit
  extensions have restricted background networking, so the container app does the
  fetching and hands results to the widget via the App Group).

### Widget extension (WidgetKit)

- Small/medium/large families.
- Shows current AQI + full pollutant breakdown.
- Per-instance configurable (which pinned location, or "current location") via App
  Intents (`WidgetConfigurationIntent`).
- `TimelineProvider` reads from the App Group cache written by the container app; does
  not fetch network or location itself.

### Data flow / mode selection

Both modes return the same JSON shape into the same `BluegullAQIKit` models:

- **Direct mode**: client → AirNow directly, using the user's own Keychain-stored key.
- **Service mode**: client → BlueGull Lambda → AirNow, using the service's own key
  (Secrets Manager/SSM, not user-supplied).

**Open question (unresolved):** default mode for a fresh install with no key entered.
Leaning toward **Service** (works immediately, no setup) with a settings toggle to
switch to Direct (higher/no rate limit, no dependency on the BlueGull backend) — but
this hasn't been explicitly confirmed yet.

### Backend service (`service/`)

- **Compute**: plain Lambda + API Gateway HTTP API. (Not using Plant-Tracer's
  Flask + Lambda Web Adapter pattern — this service is a thin JSON caching proxy, not
  a multi-route web app, so that layer would be pure overhead here.)
- **Cache**: single DynamoDB table, keyed by rounded lat/long (or zip), with a TTL
  attribute (~1 hour). This is the main protection for AirNow's own rate limit — many
  clients asking about the same area collapse into one upstream AirNow call.
- **Rate limiting**: AWS WAFv2 rate-based rule attached to the API Gateway, per-IP.
  (HTTP APIs/v2 don't support REST API v1's usage-plan + API-key throttling, hence
  WAF instead.) Known tradeoff: Macs behind CGNAT/shared office IPs will share a
  throttling bucket — coarser than per-install keys, but that's the chosen tradeoff.
- **Secrets**: the service's own AirNow API key lives in SSM Parameter Store
  (SecureString) or Secrets Manager, referenced by the Lambda's execution role. Never
  committed to source.
- **Custom domain**: Route53 hosted zone + ACM cert, same pattern as
  `planttracer.com` in Plant-Tracer's `template.yaml`. Needs an actual domain name
  (see Open Questions).
- **Scaling**: see the dedicated section below — the service must scale horizontally
  as installs grow, and that constrains the cache design, not just the infra config.
- **CI/CD**: GitHub Actions mirroring Plant-Tracer's `ci-cd.yml` (lint, pytest,
  `sam validate`/`sam build`), plus a deploy workflow. Plant-Tracer's deploy workflows
  are currently manual/off (`deploy-*.yml-OFF`) — starting the same way here: build +
  test on every push, deploy gated behind a manual trigger (`workflow_dispatch`) or
  tag push, not auto-deployed on merge, until the service is proven out.

### Scaling & performance

**Requirement**: the service must scale horizontally as the number of clients grows.
Every App Store install polls hourly, so load is a function of install count — this is
not a single-user service, and performance is a design constraint rather than a
post-hoc concern.

**The dominant risk is the cache stampede, not Lambda capacity.** Lambda scales out
on its own; DynamoDB in on-demand mode does too. What doesn't scale for free is the
upstream: when a cache entry expires and N clients ask for the same location at the
same moment, a naive design fires N concurrent AirNow calls. That is slow for clients
and a direct route to getting the project's AirNow key throttled or banned.

Mitigation, in two layers:

- **Stale-while-revalidate + single-flight.** On a miss against an expired entry,
  serve the stale value immediately, and let exactly one request win a DynamoDB
  conditional-write lock to refresh it in the background. Clients get a warm-path
  response almost always, and AirNow sees at most one call per location per TTL
  regardless of concurrency. Cold-start-of-the-world (no entry at all) still blocks,
  but that's a once-per-location event.
- **Client-side refresh jitter.** Hourly refresh means every install would otherwise
  wake at the top of the hour and synchronize into a spike. Each install derives a
  stable offset within the hour (from a per-install value, so the interval stays
  consistent rather than drifting) to spread load uniformly. Cache TTL should align
  to AirNow's publish schedule rather than being a rolling hour from first request.

Supporting choices:

- **DynamoDB on-demand billing** — no capacity planning, scales automatically. Access
  is keyed by location, which distributes well; a single overwhelmingly popular metro
  is the only plausible hot-partition risk and is not a concern at expected scale.
- **ARM64 (Graviton) Lambda** — cheaper and generally equal-or-better performance
  than x86 for this workload.
- **Cold start minimization** — keep the deployment package small (prefer the
  runtime-provided `boto3` over vendoring a copy; keep dependencies light), and create
  clients at module scope so they're built once during Init and reused across warm
  invocations. Provisioned concurrency would eliminate cold starts entirely but bills
  continuously; it's the escape hatch if Init Duration ever becomes user-visible, not
  the default.
- **Concurrency ceiling** — the account default is 1000 concurrent executions per
  region. Worth an explicit reserved-concurrency setting so this service can't starve
  anything else in the account (relevant if the AWS-account decision lands on sharing
  with Plant-Tracer).
- **Observability** — CloudWatch metrics for p50/p95 latency, error rate, concurrent
  executions, throttles, and cache hit ratio. Cache hit ratio is the leading indicator
  for everything else: if it drops, AirNow load and latency both rise.

### Local development (no AWS required)

**Requirement**: the proxy server must be runnable and testable entirely from a bash
command line, manually or in CI, without ever deploying to AWS — matching how
Plant-Tracer's Flask app runs natively against local service substitutes rather than
through SAM/Docker emulation.

- **Code structure**: the core lookup/cache logic lives in a plain Python
  function/module, separate from the Lambda entry point (`lambda_handler.py` is a
  thin wrapper around it). The DynamoDB client's `endpoint_url`/region come from env
  vars, so the identical code path runs against production DynamoDB and against
  DynamoDB Local — no separate "local mode" branch to keep in sync.
- **Cache backend locally**: **DynamoDB Local**, not an in-memory stub — same
  approach as Plant-Tracer's `bin/local_services.py` + vendored `DynamoDBLocal.jar`.
  Chosen over an in-memory dict for higher fidelity (real DynamoDB semantics,
  including the TTL behavior the production cache relies on) at the cost of needing
  a JVM locally.
- **Serving requests locally**: a **native runner** (Flask or plain
  `http.server`/`wsgiref`) that calls the same core logic directly — e.g.
  `make run-local` / `python bin/run_local.py`. Deliberately *not*
  `sam local start-api`: that route needs Docker Desktop and is slower to iterate on,
  and the goal here is zero AWS/Docker dependency for the everyday dev loop.
- **Secrets locally**: the AirNow key comes from a local env var/`.env` file, not
  Secrets Manager/SSM — nothing about local dev should require AWS credentials.
- **CI**: starts DynamoDB Local before running tests (mirroring Plant-Tracer's
  ci-cd.yml step), so the test suite never needs an AWS account or a deployment,
  automatically or manually.

## Open questions (blocking or semi-blocking)

- **Default data-source mode** for a fresh install (Service vs. Direct) — see above.
- **Domain name** for the backend's custom domain — need an actual registered domain
  / hosted zone to put in `template.yaml`.
- **AWS account**: same account as Plant-Tracer, or a separate account for this
  project? (Affects billing isolation and IAM boundaries, not the architecture.)
- **AirNow API key for the service** — not yet registered; also worth confirming
  AirNow's actual published rate limits/ToS once registering, since that bounds how
  aggressive the DynamoDB cache TTL needs to be.
- **App Group ID / bundle IDs** — not yet created in the Apple Developer portal.

## Phased build order

1. **Backend MVP** — SAM template, single Lambda, DynamoDB cache, WAF throttling,
   deployed to a dev stage. Custom domain can follow slightly after if it unblocks
   faster iteration.
2. **`BluegullAQIKit`** — models, both clients, Keychain helper, App Group cache, unit
   tests. No UI yet.
3. **Menu bar app** — location permission flow, settings (mode toggle, key entry,
   pinned-locations list), current-AQI display.
4. **Widget extension** — timeline provider, App Intents configuration for picking a
   pinned location, full pollutant-breakdown layout across widget sizes.
5. **Polish** — stale-cache/offline states, rate-limit-exceeded UX, background-refresh
   budget tuning.
6. **App Store prep** — sandbox entitlements (location, network client), privacy
   nutrition label, screenshots, review pass.

## Testing strategy

Coverage target: automate everything that doesn't require a human to approve an OS
permission dialog or wait out real system scheduling. There is no macOS equivalent of
the iOS simulator, but that turns out to matter less than it first appears — widget
*views* render headlessly, and the app *is* drivable from the command line. The
genuinely manual residue is small and enumerated at the end of this section.

The full toolchain (Xcode, `xcodebuild`, `swift`) is available locally and on GitHub's
`macos-latest` runners, so every automated tier below runs from a bash command line
with no GUI interaction.

### Backend service (`service/`)

- **Unit**: core lookup/cache logic as plain Python functions, AirNow HTTP calls
  stubbed (`responses`/`requests-mock`) — no live network.
- **Integration**: cache read/write/TTL behavior tested against DynamoDB Local — real
  DynamoDB semantics, not a mock approximation.
- **Handler contract**: sample API Gateway HTTP API event fixtures (à la Plant-Tracer's
  `events/event.json`) fed into the Lambda entry point, asserting on the wrapped JSON
  response — proves the thin-handler-over-core-logic split actually holds.
- **Template**: `sam validate`/`sam build` in CI catches infra config errors without a
  real deploy.
- **Concurrency**: the stale-while-revalidate + single-flight logic tested directly
  against DynamoDB Local — concurrent misses on the same key must produce exactly one
  upstream call, and an expired entry must be served rather than blocked on.
- Out of scope: AirNow's own uptime/behavior.
- All of the above run with no AWS account or deployment, per the local-development
  requirement above. Performance and load regression testing is a separate tier with
  different requirements — see below.

### Performance & load regression testing

Performance is a tracked, gated metric, not a one-off measurement. This tier is
deliberately separate from the functional suite above: **cold start can only be
measured on real Lambda** (the native local runner has no Init phase at all), so
these tests require a deployed dev stage. The "no AWS needed to test" requirement
still holds in full for the functional suite, which remains local and runs on every
push.

**Tracked metrics**

| Metric | Gate | Notes |
|---|---|---|
| Warm cached round-trip (p50, p95) | 5% | The common path — most requests are cache hits |
| Uncached round-trip, AirNow stubbed (p50, p95) | 5% | Isolates *our* overhead from AirNow's variability |
| Lambda cold start (Init Duration, median) | ~15% | Inherently noisy; see below |
| Throughput & error rate at 10 and 100 concurrent | 5% on p95 | The horizontal-scaling response curve |
| Cache hit ratio under load | 5% | Catches stampede-mitigation regressions directly |

Real end-to-end uncached latency (with a live AirNow call) is tracked as an
observability metric but **not** gated — it substantially measures AirNow's
performance, which we don't control, and gating on it would produce failures we can't
act on.

**Stubbing AirNow during load tests is mandatory, not an optimization.** Driving 100
concurrent uncached requests at the live AirNow API would burn the project's quota and
plausibly violate its terms. The dev stage gets a test mode (env-gated, or a reserved
synthetic location) that returns canned data in place of the upstream call.

**Statistical approach.** Gates compare percentiles over N ≥ 100 samples, never single
measurements — AWS fleet variance, DynamoDB p99 spikes, and runner noise all routinely
exceed 5% run-to-run, so a naive single-sample comparison would produce a permanently
red build. Cold start gets a wider band (~15%) because Init Duration variance is
larger than the others by a good margin; holding it to 5% would flake regardless of
sample count.

**Baseline storage.** A `perf-baseline.json` committed to the repo, holding the
metrics from the last release. Regressions therefore show up as a reviewable diff, and
accepting an intentional regression is an explicit commit rather than a silent
overwrite.

**Cadence.** Release-gated (the actual pass/fail gate, against a deployed dev stage)
plus nightly, so drift surfaces with a trend line instead of arriving all at once at
release time.

**Local proxy metric (no AWS).** Module import time and deployment package size are
measurable locally with no deployment and correlate well with Init Duration. Gating
these in the ordinary functional CI catches the most common cold-start regression —
someone adding a heavy dependency — long before the nightly perf run does.

**Tooling**: [k6](https://k6.io) for load generation. Its native threshold support
(`http_req_duration: ['p(95)<...']`) expresses pass/fail gates directly, which maps
onto the regression-gate requirement without much custom scripting. Cold start is read
from the `Init Duration` field of CloudWatch Logs REPORT lines after forcing a cold
start via fresh deploys.

### `BluegullAQIKit` (shared Swift package)

Highest-leverage place for coverage, since both UI targets sit on top of it:

- **Unit**: model decoding from fixture JSON; cache TTL logic with an injected fake
  clock; Keychain round-trip (runs fine in CI on macOS runners).
- **Contract test**: `AirNowDirectClient` and `BluegullServiceClient` fed
  structurally-equivalent fixture payloads must decode to identical model instances —
  verifies the "client code doesn't care which source answered" design claim instead
  of just asserting it in prose.
- **Networking**: both clients' networking stubbed via `URLProtocol` — no live AirNow
  or backend calls in CI.
- **LocationResolver**: exposed behind a protocol so tests can inject a fake
  location/geocoder — CI can't exercise real GPS or live geocoding.

### Menu bar app & widget extension

Logic is pushed down into `BluegullAQIKit` wherever possible so these targets stay
thin. What remains is tested in three tiers, ordered by value-per-unit-of-pain:

**Tier 1 — headless view rendering (highest value).** A WidgetKit widget's view is
just a SwiftUI view that takes a timeline entry; it does not need the widget host to
render. `ImageRenderer` (macOS 13+) rasterizes it to a PNG at any size, so the
small/medium/large layouts are rendered from fixture entries directly in a test. Two
uses:

- *Snapshot regression tests* — golden PNGs committed to the repo and compared per
  run. [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
  supports SwiftUI on macOS and is the mature option; the dependency-free alternative
  is a small `ImageRenderer` + PNG-comparison helper. Either way it's a test-only
  dependency and does not ship in the App Store build.
- *Direct visual inspection* — the same renderer can emit PNGs on demand for a human
  (or an agent that can display images) to eyeball, without any test needing to fail
  first.

This tier catches the failure modes this widget is actually prone to: AQI 500 vs. 5
changing the layout, a full pollutant breakdown overflowing the large widget,
missing-data and stale-cache states, light/dark mode, and Dynamic Type sizes.

**Tier 2 — XCUITest for the menu bar app.** `xcodebuild test` runs XCUITest, which
launches the container app and drives it through the accessibility hierarchy;
`NSStatusItem` menu bar extras are queryable. Covers settings flows, data-source mode
toggling, and pinned-location management. Known cost: menu bar automation is finicky,
and CI needs a logged-in GUI session plus TCC/accessibility permission for the test
runner — the usual "passes locally, hangs in CI" trap. Budget frustration for it.

**Tier 3 — driving the real widget in Notification Center** (`osascript` +
`screencapture`). Deliberately **not** planned: it mostly exercises Apple's widget
host rather than our code, and it's brittle. Revisit only if a bug appears that
reproduces solely under the real host.

Also unit-tested, independent of rendering:

- **TimelineProvider**: fed a fixture App Group cache state, asserting on the produced
  timeline entries.
- **App Intents**: the configuration intent's `perform()` logic tested directly.

### What stays manual

Small, and genuinely not automatable:

- The location permission (TCC) dialog — cannot be legitimately scripted away.
- iCloud Keychain sync across two *physical* Macs.
- Real WidgetKit background-refresh budget behavior, which plays out over hours of
  system scheduling rather than in a test run.
- App Review.

*Unverified:* whether a supported CLI exists to force an installed widget to reload
its timeline. Worth checking before relying on it; nothing in the plan currently
depends on it.

### CI layout

Two GitHub Actions workflows, split by directory like the repo layout: one for
`service/` (lint, pytest against DynamoDB Local, `sam validate`/`sam build` — no
deploy), one for `mac-app/` (`xcodebuild test` on `macos-latest`, covering unit,
snapshot, and XCUITest suites). Neither requires an AWS account, an AWS deployment,
or Docker.

All of it wraps into `make` targets following Plant-Tracer's idiom — e.g.
`make test-swift`, `make snapshots`, `make test` for everything.

## Task tracking

Implementation work is tracked in [Beads](https://github.com/steveyegge/beads)
(`bd`), not in this file — this document stays the design record; `.beads/` is the
source of truth for what's done, in progress, or blocked. One epic per phase above:

| Phase | Epic |
|---|---|
| 0. Prerequisites & open decisions | `bluegull-aqi-8ef` |
| 1. Backend service MVP | `bluegull-aqi-q9r` |
| 2. BluegullAQIKit shared package | `bluegull-aqi-10h` |
| 3. Menu bar app | `bluegull-aqi-e70` |
| 4. Widget extension | `bluegull-aqi-mtm` |
| 5. Integration polish | `bluegull-aqi-dc2` |
| 6. App Store submission prep | `bluegull-aqi-fw4` |

Run `bd ready` to see unblocked work, `bd dep tree <epic-id>` to see a phase's
breakdown, or `bd show <id>` for any issue's detail. The Open Questions above are
tracked as `decision`/`task` issues under the Phase 0 epic and block the downstream
work that depends on them (e.g. the domain-name decision blocks the Route53/ACM
template task).

The repo lives at [github.com/sbarber2/bluegull-aqi](https://github.com/sbarber2/bluegull-aqi)
(public), with a Dolt remote configured against the same URL — `bd dolt push`/
`bd dolt pull` sync issues cross-machine via `refs/dolt/data`, alongside the normal
`main` branch. `.beads/issues.jsonl` is also auto-exported and committed as a
human-readable snapshot, but the Dolt remote is the actual sync mechanism.

## Changelog

- 2026-07-27 — Initial design captured from planning discussion.
- 2026-07-27 — Renamed `docs/` to `doc/`. Initialized Beads task tracking with one
  epic per phase and issues/dependencies for every task in the phased build order.
- 2026-07-27 — Added the local-development requirement: the proxy server must run
  and be testable from a bash command line without ever deploying to AWS, using
  DynamoDB Local for the cache backend and a native (non-Docker) local runner.
- 2026-07-27 — Created the GitHub repo (sbarber2/bluegull-aqi, public), pushed the
  code, and wired a Dolt remote so Beads issues sync cross-machine.
- 2026-07-27 — Added a Testing Strategy section covering all four deliverables, with
  the explicit gap that on-screen/on-device behavior needs a manual smoke test since
  no macOS-app simulator tooling is available in this workflow. Added 8 corresponding
  Beads tasks (handler contract tests, kit contract/network-stub tests, Swift CI
  workflow, widget unit tests, and manual on-device smoke-test checkpoints for the
  menu bar app and widget).
- 2026-07-27 — **Corrected a design error**: an earlier revision listed load/perf
  testing as out of scope because the project was "single-user-scale." That was
  wrong — every App Store install polls the service hourly, so load scales with
  install count and horizontal scalability is a stated requirement. Added a Scaling &
  Performance section (stale-while-revalidate + single-flight stampede mitigation,
  client-side refresh jitter, on-demand DynamoDB, ARM64 Lambda, cold-start
  minimization, CloudWatch observability) and a Performance & Load Regression Testing
  section with gated metrics, a committed `perf-baseline.json`, and release-gated +
  nightly cadence. Added 12 Beads tasks.
- 2026-07-27 — **Revised the above**: the "must be manual" claim was too pessimistic.
  Widget views render headlessly via `ImageRenderer` (no widget host needed), and
  XCUITest can drive the menu bar app from the command line — so snapshot regression
  testing and UI automation are both in scope. The two manual checkpoints shrank to
  the genuine residue: TCC permission dialogs, cross-Mac iCloud Keychain sync, and
  real background-refresh scheduling. Added 5 Beads tasks (ImageRenderer harness,
  snapshot tests, XCUITest suite, Makefile test targets, and a low-priority
  investigation of the unverified widget-reload CLI question).
