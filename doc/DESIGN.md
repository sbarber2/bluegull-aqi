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
- **CI/CD**: GitHub Actions mirroring Plant-Tracer's `ci-cd.yml` (lint, pytest,
  `sam validate`/`sam build`), plus a deploy workflow. Plant-Tracer's deploy workflows
  are currently manual/off (`deploy-*.yml-OFF`) — starting the same way here: build +
  test on every push, deploy gated behind a manual trigger (`workflow_dispatch`) or
  tag push, not auto-deployed on merge, until the service is proven out.

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

Coverage target: everything below the OS-integration boundary is automated; actual
on-screen rendering, location permission prompts, and App Group data flow between two
live processes are **not** — there is no macOS-app equivalent of an iOS simulator
available in this workflow, so those need a manual on-device pass by whoever's
driving the build. That gap is called out explicitly below rather than implied.

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
- Out of scope: AirNow's own uptime/behavior, load/perf testing (single-user-scale).
- All of the above run with no AWS account or deployment, per the local-development
  requirement above.

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
thin:

- **TimelineProvider**: unit-tested by feeding it a fixture App Group cache state and
  asserting on the produced timeline entries — doesn't require the widget to render.
- **App Intents**: the configuration intent's `perform()` logic unit-tested directly.
- **Visual**: SwiftUI previews across small/medium/large widget families and menu bar
  states, for manual eyeballing. No automated visual-regression tooling planned
  initially — would be a deliberate future addition, not default-included.
- **CI**: `xcodebuild test` on a `macos-latest` GitHub runner covers everything above.
- **Manual on-device smoke test** (not automatable): build and run in Xcode on a real
  Mac at the end of Phase 3 and Phase 4 — location permission flow, both data-source
  modes, pinned-location management, hourly refresh, and all three widget layouts
  actually picking up what the container app wrote to the App Group cache.

### CI layout

Two GitHub Actions workflows, split by directory like the repo layout: one for
`service/` (lint, pytest against DynamoDB Local, `sam validate`/`sam build` — no
deploy), one for `mac-app/` (`xcodebuild test` on `macos-latest`). Neither requires
an AWS account, an AWS deployment, or Docker.

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
