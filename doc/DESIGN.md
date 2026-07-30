# BlueGull AQI — Design

Status: **early implementation**. `service/` and `mac-app/BluegullAQIKit/` are
scaffolded (buildable, tested, no real behavior yet); everything else is still
design and task graph. This file is the living design document for the project;
update it as decisions change instead of letting the chat history be the source of
truth.

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
| Business model / monetization | **For-profit** (changed 2026-07-30 — originally planned as non-profit). Collects money via the App Store (In-App Purchase/subscription/paid app — exact mechanism still open, a pricing detail for `bluegull-aqi-fw4`) to cover infrastructure costs, with flexibility to eventually pay Steve for ongoing operations. Reopens the AirNow commercial-use question the original terms review left unresolved — tracked at P0 in `bluegull-aqi-8ef.15`. |
| Web service client auth / rate limiting | Anonymous, no per-install keys, no login. Not IP-based -- AWS WAFv2 can't attach to an HTTP API (v2), only REST APIs/ALB/etc. (found and corrected 2026-07-30, bluegull-aqi-q9r.5). Relies instead on API Gateway stage throttling, Lambda reserved concurrency, and a global cache-miss budget (bluegull-aqi-q9r.32). |
| Menu bar app data scope | The menu bar extra (status item) itself shows current overall AQI only — no room for more. Clicking it opens a `.window`-style popover with full detail (pollutant breakdown, attribution, preliminary-data disclaimer), matching the widget's content. This is the guaranteed access point for compliance content regardless of whether the user has placed the desktop widget. |
| Widget data scope | Current AQI **and** full per-pollutant breakdown (PM2.5, PM10, ozone, etc.). |
| Location scope | Current location (CoreLocation) **and** user-pinned locations (zip/address, geocoded locally via `CLGeocoder`/MapKit — no backend geocoding endpoint needed). |
| Refresh cadence | Hourly, matching AirNow's own publish cadence. |
| Minimum macOS version | macOS 14 (Sonoma) — required for desktop WidgetKit widgets anyway. |
| Backend custom domain | Three environments, one hosted zone. **Prod** = bare `aqi.bluegull.org`. **Dev** = `dev.aqi.bluegull.org`. **Staging** = `stage.aqi.bluegull.org`. All three are dot-subdomains of `aqi.bluegull.org`, so all three live under the single Route53 hosted zone in AWS account `843088391598`, delegated from `bluegull.org`'s DNS at **Squarespace** (registrar; everything else there untouched). **✅ Delegation confirmed live 2026-07-28.** Mirrors Plant-Tracer's `${StackName}.${BaseDomain}` pattern. **Second domain added 2026-07-30:** a parallel delegation for `aqi.bluegull.solutions` (mirroring the same prod/dev/stage pattern, alongside `bluegull.org`, not replacing it — `bluegull-aqi-8ef.18`). Note: unlike `bluegull.org`, `bluegull.solutions` is registered at Squarespace but its actual authoritative DNS is at **DreamHost** — the NS delegation record was added in DreamHost's panel, not Squarespace's. **✅ Delegation confirmed live 2026-07-30** (`dig NS aqi.bluegull.solutions` returns the 4 Route53 nameservers). |
| AWS region | **`us-east-2`** (Ohio), chosen for cost over the Plant-Tracer-matching default of us-east-1. `service/samconfig.toml` deploys here. No conflict with the custom domain: `AWS::Serverless::HttpApi` custom domains are regional-only (unlike REST API v1's edge-optimized option), so the ACM cert for whichever domain(s) end up wired into `template.yaml` (`aqi.bluegull.org`, `aqi.bluegull.solutions`, or both — `bluegull-aqi-q9r.6`) just needs to be in this same region. The one exception: if CloudFront (`bluegull-aqi-q9r.33`, deferred) is ever adopted, its ACM cert must be in **us-east-1** specifically — a hard CloudFront-wide rule, independent of the API's own region. |
| AWS account | **`843088391598`**, dedicated to this project (not shared with Plant-Tracer) — gives the blast-radius isolation the Scaling & Performance section already assumed. Standalone account, its own IAM Identity Center instance (not part of Plant-Tracer's org). CLI access: `aws sts get-caller-identity --profile AdministratorAccess-843088391598` — an assumed role via `AWSReservedSSO_AdministratorAccess`, not root; re-authenticate with `aws sso login --profile AdministratorAccess-843088391598` when the session expires. |
| Apple Developer account | Already enrolled as **Individual** (confirmed 2026-07-30, `bluegull-aqi-8ef.22`) — App Store seller shows Steve's personal name for now, not a company. **Decided:** proceed under Individual rather than pause for LLC formation; convert to Organization once **BlueGull Solutions LLC** exists and revenue justifies forming it (deliberately not before — an LLC doesn't retroactively shield pre-formation activity, and nothing is live/collecting money yet). Conversion path (Apple support-mediated, or fresh Organization enrollment + App Transfer) preserves the app's reviews/ratings/bundle-id string either way; the Team-ID-scoped portal registration and local Xcode signing config are not guaranteed to carry over in the fresh-enrollment path, but that rework is cheap relative to pausing now. **✅ Bundle IDs and App Group registered 2026-07-30** (`bluegull-aqi-8ef.5`): `solutions.bluegull.aqi` (container app) and `solutions.bluegull.aqi.widget` (widget extension), both with the App Groups capability enabled and attached to App Group `group.solutions.bluegull.aqi` — matching what's already hardcoded in `AppGroupCache.swift`/`AirNowAPIKeyStore.swift`. Unblocks `bluegull-aqi-e70.1` (scaffold the Xcode project). |
| AQI category colors | Official EPA AQI RGB palette only, sourced once in `BluegullAQIKit`'s shared models and used by both the menu bar and widget — never a custom palette. Compliance requirement from the AirNow Data Exchange Guidelines, not a style preference; see "AirNow terms review" below. |

## Secrets & credentials

**No credential, API key, token, certificate, or private key is ever committed to
this repository.** This is a hard invariant, not a preference — the repo is public,
and a leaked key in git history is leaked permanently even after a follow-up commit
removes it. Rotation, not deletion, is the only real remedy once it happens.

### Inventory — every secret in this project and where it lives

| Secret | Home | Never |
|---|---|---|
| Service's AirNow API key | SSM Parameter Store, SecureString, `/bluegull-aqi/airnow-api-key` (one key shared across dev/stage/prod), read by the Lambda execution role | In source, in `template.yaml`, or as a CloudFormation parameter default |
| User's own AirNow API key (direct mode) | iCloud Keychain on the user's Mac | Bundled in the app binary or in any repo file |
| Local dev AirNow key | **1Password** (BlueGull vault, item "BlueGull AQI - AirNow API Key", API Credential type, `credential` field), referenced from `.env` as `op://BlueGull/BlueGull AQI - AirNow API Key/credential` and resolved only at invocation via `op run --env-file=.env -- <command>` — never written to disk as a literal, never persists in the shell beyond that one process. `.env` itself stays gitignored regardless (see `.env.example`). `.envrc` (direnv) is an equally tempting place to stash a secret as a plain `export`, and needed its own explicit `.gitignore` line — `.env.*` does **not** match that filename; found holding this key as a literal mid-project and corrected (see changelog). | Committed, even "temporarily"; resolved into a persistent shell env var (`.envrc`-style) rather than a single process's lifetime |
| AWS deploy credentials | GitHub Actions OIDC role assumption — no long-lived keys exist to leak | Long-lived access keys in GitHub secrets or `~/.aws` in CI |
| Apple signing cert / App Store Connect API key | GitHub Actions encrypted secrets, imported to a temporary keychain at build time | Committed, or left in a persistent CI keychain |

### Project-specific leak vectors worth naming

- **AirNow passes its key as a URL query parameter** (`...&API_KEY=...`). Logging the
  request URL therefore writes the key straight into CloudWatch Logs, where it is
  readable by anyone with log access and persists for the retention period. Request
  URLs must be redacted before logging. This is the single most likely way this
  project leaks a key, and it looks like ordinary debug logging.
- **Error responses and stack traces** must not echo the upstream URL or request
  headers back to clients.
- **`samconfig.toml` is committed** (following Plant-Tracer). Secrets must never
  appear in its `parameter_overrides`; the template resolves them via SSM dynamic
  references at deploy time instead.
- **`.beads/issues.jsonl` is committed.** An API key pasted into a `bd` issue
  description lands in git like any other file. Issue text is not a scratchpad.
- **The design doc and README** — use obvious placeholders, never a real-looking key.

### Enforcement

A rule stated in a doc is not enforcement. Three layers, in order of what actually
catches things:

1. **GitHub push protection + secret scanning** — ✅ verified enabled (GitHub turns
   both on by default for public repos). Blocks a push containing a *recognized*
   credential pattern before it reaches the remote.
2. **Betterleaks as a pre-commit hook** — catches it locally before a commit exists,
   which is the cheapest possible point to catch it.
3. **Betterleaks in CI** — backstop for commits made without the hook installed (fresh
   clones, other machines, other agents).

Tool choice: gitleaks (the tool originally planned here) is now feature-complete —
its creator has moved active development to **Betterleaks**, a drop-in-compatible
successor (same config format, same CLI shape) with materially better detection for
exactly the kind of context-based rule this project needs (CEL/Expr-based validation
and token-efficiency scanning instead of pure entropy — 98.6% recall vs. 70.4% on the
CredData benchmark, per Betterleaks' own published results). Verified this against
the actual release (installed v1.7.2 via Homebrew, read `--help` output directly)
rather than trusting scraped docs, since a wrong CLI flag here would silently defeat
the whole point.

⚠️ **Pattern scanners will not catch the AirNow key on their own.** Push protection
and Betterleaks' default rules key on distinctive credential formats — AWS `AKIA…`,
GitHub `ghp_…`, Stripe `sk_live_…`. The AirNow key carries no such prefix; like most
government API keys it's a generic token, indistinguishable from any other opaque
string. So layer 1 protects the AWS and Apple credentials in the inventory above but
**not this project's primary secret**.

Closing that hole requires a **custom Betterleaks rule keyed on context rather than
token shape**: assignments to `AIRNOW_API_KEY`/`API_KEY`, and high-entropy tokens
appearing near `airnowapi.org`. Without it, the enforcement stack has a gap exactly
where it matters most — which is precisely why layers 2 and 3 are not redundant with
layer 1. Rules live in `.betterleaks.toml` (`[extend] useDefault = true` plus the two
custom rules); verified against real and placeholder values via `betterleaks stdin`
before trusting them, and dry-ran the full ruleset against this repo's entire git
history (`betterleaks git .`) to confirm zero false positives against the existing
codebase (test fixtures, `.env.example`, etc.) and zero pre-existing leaks.

The local hook lives in `.beads/hooks/pre-commit` (outside the Beads-managed marker
block, which explicitly permits additions around it) rather than the `pre-commit`
Python framework's own `.pre-commit-config.yaml` — Beads already owns
`core.hooksPath` for its own Dolt-sync hooks, and the `pre-commit` framework refuses
to install (`Cowardly refusing to install hooks with core.hooksPath set`) when
anything else already owns that git config. Calling the `betterleaks` binary
directly from the existing hook script avoids the conflict entirely and adds no new
dependency beyond the binary itself. Verified live: staged a fake `AIRNOW_API_KEY=`
value and confirmed the commit was blocked, then confirmed a clean commit still
succeeds (including Beads' own hook logic still firing normally afterward).

`.gitignore` carries secret filename patterns as a safety net, but it only helps for
files someone remembered to name conventionally. It is the weakest layer, not the
control.

If a secret does reach the repo: **rotate it first**, then clean history. Rewriting
history without rotating is theater — assume anything pushed to a public repo was
scraped within minutes.

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

Two distinct pieces, both from SwiftUI's `MenuBarExtra`:

- **The menu bar extra (status item)** — the small always-visible sliver in the
  system menu bar. Shows current overall AQI as text/icon; there's no real estate
  for anything more, including attribution or the disclaimer.
- **The popover** (`.menuBarExtraStyle(.window)`, not the plain `.menu` list style) —
  clicking the status item opens a real SwiftUI view with proper layout space,
  functionally similar in content to the widget: current AQI, full pollutant
  breakdown, the persistent "Data courtesy of {agency}" attribution footer, and the
  preliminary-data disclaimer. This is the guaranteed access point for both
  compliance elements — reachable with one click regardless of whether the user has
  ever placed the desktop widget, which the widget alone cannot guarantee.

The container app also owns: location permission flow, settings UI (data-source mode
toggle, AirNow key entry, pinned-locations list management — likely reached from
within the popover, e.g. a gear icon, rather than a separate window), and the actual
network fetch (WidgetKit extensions have restricted background networking, so the
container app does the fetching and hands results to the widget via the App Group).

### Widget extension (WidgetKit)

- Small/medium/large families.
- Shows current AQI + full pollutant breakdown.
- Per-instance configurable (which pinned location, or "current location") via App
  Intents (`WidgetConfigurationIntent`).
- `TimelineProvider` reads from the App Group cache written by the container app; does
  not fetch network or location itself.
- **Tap-to-expand**: the whole widget is a tap target (`widgetURL`) that deep-links
  into the container app, which opens a detail view — the same pattern Apple's own
  Weather widget uses. v1 scope for that view is attribution + the preliminary-data
  disclaimer (reusing the menu bar popover's content rather than a third separate
  surface). A richer expanded view showing more than the widget face currently does
  is deliberately deferred past v1 — see `bluegull-aqi-mtm.15`.

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
- **AirNow endpoint**: `GET https://www.airnowapi.org/aq/observation/current/ziplatlong/`
  (`?format=application/json&latitude={lat}&longitude={lon}&API_KEY={key}`).
  **Not** the "classic" `/aq/observation/latLong/current/` endpoint most tutorials and
  training data reference — EPA is retiring that one (and five siblings) on
  **September 30, 2026**, per their official migration notice (found via a dated,
  merged `pyairnow` PR migrating for the same reason, then confirmed directly against
  EPA's own PDF and a live test query). Response is a JSON array, one object per
  pollutant, confirmed against a real query:
  ```json
  {
    "dateObserved": "2026-07-29", "hourObserved": "14:00", "localTimeZone": "PDT",
    "reportingAreaName": "San Francisco", "siteID": "060750005", "siteName": "San Francisco",
    "parameterName": "PM2.5", "nowcastAQI": 31, "aqiCategoryName": "Good",
    "reportingAgency": "Bay Area Air District",
    "lookupBehavior": "Closest Reading By Pollutant", "consideredMonitors": "All",
    "lookupBoundary": "50 Miles"
  }
  ```
  `reportingAgency` answers `bluegull-aqi-10h.15`'s attribution question directly — no
  fallback needed for the common case. Error shape:
  `{"WebServiceError": [{"Message": "..."}]}`, empty array if no data. Never derive
  `nowcastAQI` ourselves — display as received, per `bluegull-aqi-10h.17`.
- **Cache**: single DynamoDB table, keyed by rounded lat/long (or zip), with a TTL
  attribute (~1 hour). This is the main protection for AirNow's own rate limit — many
  clients asking about the same area collapse into one upstream AirNow call.
- **Rate limiting**: not per-IP. HTTP APIs/v2 don't support REST API v1's usage-plan
  + API-key throttling, and — found while implementing `bluegull-aqi-q9r.5` — AWS
  WAFv2's `WebACLAssociation` doesn't support HTTP API (v2) either, only REST APIs,
  ALB, Cognito, AppSync, App Runner, Verified Access, and Amplify (confirmed against
  AWS's current CloudFormation docs). Decided, with Steve's input, not to chase WAF
  support for this by migrating to a REST API or fronting the HTTP API with
  CloudFront (`bluegull-aqi-q9r.33`, still a "later if scale justifies it" candidate)
  — relies instead on API Gateway stage throttling (a hard, global rate/burst cap,
  `bluegull-aqi-q9r.31`), Lambda reserved concurrency, and the cache-miss budget
  (`bluegull-aqi-q9r.32`). None of those are per-IP, so a single misbehaving client
  can still exhaust the shared budget for everyone — an accepted tradeoff at this
  scale, not an oversight.
- **Secrets**: the service's own AirNow API key lives in SSM Parameter Store
  (SecureString) or Secrets Manager, referenced by the Lambda's execution role. Never
  committed to source.
- **Custom domain**: three stacks, one hosted zone, mirrored across **two** domains
  as of the 2026-07-30 business-model pivot (`bluegull-aqi-8ef.18`) — `aqi.bluegull.org`
  (prod) / `dev.aqi.bluegull.org` / `stage.aqi.bluegull.org`, and the equivalent
  `aqi.bluegull.solutions` / `dev.aqi.bluegull.solutions` / `stage.aqi.bluegull.solutions`,
  each set of three as dot-subdomains under its own single Route53 hosted zone in AWS
  account `843088391598`. Added, not migrated — both stay live; see "Decisions made so
  far" for which is registered where. **✅ Both delegations live**: `bluegull.org`'s DNS
  stays at Squarespace (the registrar) for everything else, `bluegull.solutions`'s
  actual DNS is at DreamHost (different from its registrar, Squarespace) — the NS
  record for `aqi` was added at each provider's own panel and confirmed resolving to
  Route53 (`dig NS` returns the 4 `awsdns` nameservers for both). ACM cert(s) can now
  be DNS-validated for either. Same `${StackName}.${BaseDomain}` naming pattern as
  Plant-Tracer's `template.yaml`; `q9r.6` (actually wiring ACM + the API Gateway custom
  domain in `template.yaml`) still decides which domain(s) `BaseDomain` resolves to.
- **Scaling**: see the dedicated section below — the service must scale horizontally
  as installs grow, and that constrains the cache design, not just the infra config.
- **CI/CD**: GitHub Actions mirroring Plant-Tracer's `ci-cd.yml` (lint, pytest,
  `sam validate`/`sam build`), plus a deploy workflow covering the three stacks
  above. Plant-Tracer's per-environment deploy workflows are currently manual/off
  (`deploy-dev.yml-OFF`, `deploy-demo.yml-OFF`, `deploy-production.yml-OFF`) —
  starting the same way here: build + test on every push, deploy to any stack gated
  behind a manual trigger (`workflow_dispatch`) or tag push, not auto-deployed on
  merge, until the service is proven out.

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

## Security & abuse resistance

### Threat model

The API is public and unauthenticated by design — anonymous, IP-based rate limiting,
no accounts. That's a deliberate tradeoff, and it means the design has to assume any
caller, not just our app.

What's actually worth protecting, in priority order:

1. **The AWS bill.** On a fully elastic stack this is the softest target and the one
   with real personal consequences.
2. **The AirNow key and its quota.** Losing it takes the whole service down and can't
   be fixed by scaling.
3. **User location privacy.** The most sensitive data the system touches.
4. **Availability.** Genuinely last — this is a background widget refreshing hourly.
   An outage means a stale AQI reading, not a broken workflow.

What's *not* in the threat model, which is why the surface stays small: no user
accounts, no credentials to steal, no writes, no stored user data, no PII beyond
transient location. One read-only endpoint.

### Denial of wallet

**The primary threat on this architecture.** An attacker doesn't need to take the
service down — Lambda, API Gateway, and on-demand DynamoDB all scale elastically,
which means they all *bill* elastically. A sustained flood costs money at a rate
nothing in the base design bounds. Per-IP rate limiting (WAF, had it been usable —
see "Rate limiting" above, it isn't for an HTTP API v2) would do little against a
botnet or a handful of cheap cloud instances anyway, and WAF bills per request
itself, so under attack it would have amplified cost rather than capped it — one
more reason not chasing it wasn't a real loss for this specific threat.

Controls that actually bound the burn rate:

- **Lambda reserved concurrency** — a hard ceiling on concurrent executions, and
  therefore on cost per unit time. This is the primary circuit breaker, not merely a
  noisy-neighbor courtesy.
- **API Gateway stage throttling** — a hard request-rate cap, independent of WAF.
- **AWS Budget alarms** — the difference between noticing in an hour and noticing on
  the monthly invoice. Must exist before the first deploy.
- **DynamoDB on-demand has no ceiling by design.** That elasticity is the point of the
  billing mode and a liability here; the Lambda concurrency cap is what indirectly
  bounds it.

This also bears on the open AWS-account decision: sharing an account with Plant-Tracer
means a cost attack here can disrupt that project too. Separate accounts is a
blast-radius argument, not just bookkeeping.

### Cache-cardinality attack

Specific to this design, and the stampede mitigation does **not** cover it.

The cache is keyed on rounded lat/long. An attacker requesting a million *distinct*
coordinates produces a million cache misses, each triggering an upstream AirNow call —
burning the AirNow quota (likely getting the key banned), filling DynamoDB with junk,
and running up Lambda cost. Stale-while-revalidate plus single-flight collapses
concurrent requests for the *same* key and does nothing here.

Mitigations, cheapest first:

- **Validate inputs and reject coordinates outside AirNow's coverage area** before any
  upstream call. A request for the middle of the Pacific should cost a 400, not an
  AirNow request.
- **Snap to a coarse grid**, bounding total key cardinality to a finite number.
- **Rate-limit cache misses specifically**, separately from overall request rate — the
  stronger version, since misses are what cost money and quota.

### Location privacy

Not an attack — a design consequence, and much cheaper to prevent than to unwind.

The service receives coordinates and logs requests, so CloudWatch logs would
accumulate "IP X was at location Y at time Z" for the whole retention period. That is
an inadvertent location-history database, and a poor fit for an app whose entire
purpose is local environmental data.

- **Round coordinates client-side before transmission.** AirNow resolves to the
  nearest monitoring station regardless, so ~1km precision costs nothing in accuracy
  and improves cache hit rates. The server never receives a precise location.
- **Never log raw coordinates** — same discipline as the API-key redaction.
- **The App Group cache holds the user's location history on disk.** Worth bounding
  retention and reviewing file protection; the locations matter more than the AQI
  values do.

### Deliberately out of scope

Recorded so these get re-argued rather than silently adopted:

- **AWS Shield Advanced** (~$3,000/month) — absurd at this scale. Shield Standard is
  automatic and free.
- **User accounts / authenticated API** — already decided against; anonymous access is
  the product choice.
- **WAF entirely** — not just managed rule sets. Confirmed unusable against this
  architecture's HTTP API (v2) without a bigger change (REST API migration or
  CloudFront), and a read-only endpoint taking two numeric parameters has almost no
  injection surface anyway, so WAF's other value (managed rule sets) wasn't buying
  much here either. See "Rate limiting" above.
- **Multi-region, penetration testing** — not until scale justifies them.

**Strong later candidate: CloudFront in front of the API.** The response is identical
for everyone in a region and changes hourly, which is nearly an ideal CDN workload. It
would absorb most traffic at the edge before reaching Lambda, cutting cost and attack
surface together — and it's also the path back to WAF (which does support CloudFront
distributions directly) if true per-IP throttling turns out to matter later. Not
worth the complexity pre-launch; the natural first move if scale materializes.

### App Attest on native macOS — resolved (bluegull-aqi-10h.14)

**Yes, as of macOS 27.** Previously unsupported on native macOS/Catalyst (`DCAppAttestService.shared.isSupported`
reliably returned `false`, even on Secure Enclave-equipped Macs); confirmed now
supported "on all Apple platforms, including macOS 27 and higher" per Apple's own
WWDC guidance. Always gate on `isSupported` at runtime rather than branching on OS
version, since availability can depend on more than just the OS (see below).

Two caveats that matter for this project specifically:

- **Extension-type restriction is moot here.** App Attest is only available from
  the main app plus Action and SSO app extensions — not from a WidgetKit extension.
  That would matter if the widget made its own network calls, but it doesn't: the
  container app owns all networking and hands results to the widget through the App
  Group cache ("Widget extension (WidgetKit)" above). So App Attest, if adopted,
  would only ever need to run in the main app.
- **Requires full security mode + SIP enabled.** On macOS, App Attest keys are
  policy-bound to the Mac being in full security mode with System Integrity
  Protection on. A user who's disabled SIP (not rare among developers/power users)
  would fail `isSupported` and need a fallback path anyway — attestation can
  never be assumed universally available even on macOS 27+.

**Sketch of what adopting it would require**, since "supported" isn't "trivial":
client-side, generate and persist an attestation key via `DCAppAttestService`, run
the one-time attestation ceremony against Apple's servers, then produce a fresh
assertion per backend request. Server-side is the bigger lift: `lambda_handler.py`
would need new verification logic -- validating the attestation/assertion against
Apple's App Attest root certificate chain, and tracking each key's signature
counter server-side (in the existing DynamoDB table, most naturally) to detect
replay. That's a real new feature, not a config flag, and it would raise this
project's minimum supported macOS to 27 specifically to gate on it meaningfully --
a product tradeoff, not just an implementation detail. Left as a future candidate
in the deferred-work table below, not undertaken now; this task's scope was the
yes/no and the sketch, not the implementation.

## AirNow terms review — research findings

Primary-source research for `bluegull-aqi-8ef.10`, done 2026-07-27. This was
fact-gathering to support a decision, not a legal conclusion in itself.

**Resolved 2026-07-28**: after reviewing the Data Exchange Guidelines, the AirNow API
FAQ and Fact Sheet, and the AQI Technical Assistance Document, the project owner
determined that caching AirNow data and redistributing it to end users via a proxy
server is permitted — Service mode proceeds alongside Direct mode. The P0 gate on all
implementation is lifted. The compliance *obligations* catalogued below are unaffected
by that determination and remain tracked (`bd list --label compliance`); they gate App
Store submission, not the start of implementation.

### What the operative agreement actually is

There is no separate "API Terms of Service" distinct from the
[**AirNow Data Exchange Guidelines**](https://docs.airnowapi.org/docs/DataUseGuidelines.pdf)
(EPA document, last updated August 2025). The account-registration page confirms this
guidelines document is what a registrant agrees to — confirmed by fetching both the
registration page and the PDF directly. It applies uniformly across AirNow.gov,
AirNow-Tech, and the AirNow API. Structurally, it's a short set of principles
presented as a form to be signed and emailed to `dmc@airnowtech.org`, not a
clickthrough EULA.

### The big question: does it permit Service mode? — Reassuring, not certain

**Nothing in the guidelines prohibits redistribution**, and the API FAQ page
affirmatively encourages exactly our caching pattern:

> "cache daily or hourly air quality observation or forecast data retrieved via web
> services" … one acceptable method is to "populate your own database"

The one caveat in that same FAQ: web services are "designed for end users to make
requests for forecasts or data for a selected area, not for looping through all zip
codes to populate a database" — bulk backfill should use AirNow's file products
instead. Our design doesn't do that: we cache opportunistically per real user
request, not by proactively enumerating locations, so this caveat reads as
inapplicable rather than as a partial conflict — but that reading is exactly the kind
of thing worth Steve's independent eye rather than taking my parsing of it at face
value.

The guidelines' language throughout ("end users who receive these data," "products,
publications... or any other related distribution") reads as assuming and
accommodating third-party redistribution, provided the obligations below are met. I
did not find anything resembling a prohibition on one party fetching on behalf of
others.

### On using EPA's own apps as evidence

Where the sections below cite what the official AirNow website or iOS app actually
does, that is **corroborating evidence of customary practice, not a substitute for
the written guidelines**. Precisely stated: **EPA is not bound by the Data Exchange
Guidelines it imposes on third-party users** — the guidelines govern how *recipients*
of the data must handle it, not EPA's own use of data it produced or collected in the
first place. So EPA's app is not a party demonstrating its own compliance with a rule
that binds it; it's simply the rule-writer's product. That makes its choices useful
evidence of what EPA would likely *find* compliant enough from someone else — a
reasonable signal of intent and tolerance — but not proof, since EPA could easily go
further than it requires of others, and nothing about its own app is bound by the
document at all. The written guidelines are what actually control; Steve's reading of
that text governs, and app precedent below is offered as input to that judgment, not
as a finding in itself.

### Concrete obligations the current design does not yet satisfy

These aren't optional — the guidelines state them as "should"/"must." All five are now
tracked as Beads tasks (each cross-referenced below) rather than living only as prose
in this section — a prior pass through this review documented the AQI-color item
without turning it into an actioned task, and it went unnoticed until a later
spot-check. Don't repeat that: a finding isn't done until it's a task with real
dependencies, not just a paragraph here.

1. **Two-tier attribution, not just "data from AirNow."** The guidelines require
   credit to go *first* to "the appropriate source — federal, state, local, and
   tribal air quality agencies" and *then* to "the EPA AirNow program." The current
   README credits only AirNow/EPA.

   **Corroborated by precedent, not settled by it** (see caveat above) — checked
   live against airnow.gov (2026-07-28, San Francisco): the site shows a persistent
   small footer reading **"Data courtesy of / Bay Area Air District"** — the actual
   local agency name, not a generic class credit — alongside a separate
   **"EPA and PARTNERS"** logo lockup. This is one EPA product's approach to these
   guidelines, and it's useful evidence that per-reading agency attribution is at
   least *available* in AirNow's own data (their system computes and displays a
   specific agency name per location, so the field exists) — it does not by itself
   establish that this placement or wording is what the written guidelines require.

   Two things this precedent changed in how the task was scoped, subject to the
   caveat above: it's now framed as per-*reading-area* agency attribution being the
   expected case rather than a fallback for when data happens to support it; and
   placement moved to the **persistent primary UI** rather than a Settings/About
   screen, since that's where the reference implementation puts it. Both remain
   open to Steve's final read of the guidelines text, not closed by what one app does.

   Tracked as `bluegull-aqi-10h.15` (derive the "courtesy of {agency}" text — find
   the response field or lookup that supplies it), `bluegull-aqi-e70.10` (surface it
   in the menu bar popover), and `bluegull-aqi-mtm.14` (surface it in the widget, via
   tap-to-expand — see below); all three gate App Store submission. **Resolved**: the
   widget does need this too, not just the popover — see the tap-to-expand pattern
   below.
2. **A "preliminary data" disclaimer, in the product itself.** "If observational data
   are used for analyses, displayed on web pages, or used for other programs or
   products, the... products must indicate that these data are preliminary."

   Steve reports the official AirNow **iOS app** places this in an About page,
   reached from the app's dropdown menu — not the persistent-footer treatment
   attribution gets. He has not located an equivalent disclaimer on airnow.gov itself
   (and isn't asking for further digging on that point; happy to assume it's there
   somewhere). Per the caveat above, an About-page placement in one app is evidence
   that EPA's own team considered menu-accessible placement acceptable for this
   specific requirement — it is not confirmation that it's the only compliant
   option, or even that it clears the bar, since "products must indicate" could
   reasonably be read to want something less buried than a menu item. This placement
   question is Steve's to resolve against the actual text, not something the iOS
   app's behavior resolves on its own.
   Tracked as `bluegull-aqi-dc2.4` (popover) and `bluegull-aqi-mtm.14` (widget); both
   gate App Store submission.

**The widget's tap-to-expand pattern** (resolves the "does the widget need this too"
question above): like Apple's own Weather widget, clicking/tapping the AQI widget
opens the container app to a larger detail view, via WidgetKit's `widgetURL` — the
whole widget is a tap target that deep-links into the app, which shows a proper
view in response. That view is the natural home for the widget-side attribution and
disclaimer, reusing content from the menu bar popover rather than maintaining two
separate compliance surfaces. New task: `bluegull-aqi-mtm.15`.

**Deferred, explicitly not for v1** (`bluegull-aqi-mtm.14`): that same expand-on-tap
detail view is a natural place to eventually show richer data than the widget's face
currently does — more like Apple Weather's expanded view than a compliance-only
screen. Good scope creep, correctly out of scope for the first release; tracked so
it isn't lost, not to imply it's imminent.
3. **No alteration — including AQI colors.** Data "should not be altered in any way
   and should be disseminated as received," and observed/forecast values "should be
   disseminated in accordance with the AQI and corresponding RGB colors" per EPA's
   AQI technical assistance document. This is a concrete widget-design constraint:
   use the official EPA AQI category colors, not a custom palette, and don't
   recompute or re-derive AQI values ourselves.
   Tracked in the Decisions table above and wired into `bluegull-aqi-10h.2` (shared
   mapping) plus all four UI display tasks (`mtm.4/5/6`, `e70.6`).
4. **Notify AirNow that this product exists.** The guidelines state that
   "publications, analyses, products... that rely on these data must be made known to
   the relevant... agencies and the EPA AirNow program" — and the Data Exchange
   Guidelines document is literally structured as a form for exactly this
   notification, to be emailed to `dmc@airnowtech.org`. Reads as a real procedural
   step, not just a norm; cheap to do regardless of how the rest of this review lands.
   Tracked as `bluegull-aqi-8ef.13`.
5. **Keep contact information current with AirNow** — an ongoing obligation, not a
   one-time item. Tracked as `bluegull-aqi-8ef.14`, filed as a standing reminder
   rather than a task with a natural "done" state.

### A soft tension worth a judgment call, not a fix

The guidelines say end users "should be provided with the most current data
available," and separately that "the AirNow program updates all data feeds several
times per hour." Our design caches for a full hour (matching AirNow's own
*observation* cadence, which is the standard granularity consumer AQI apps use). This
isn't a clear conflict — hourly is a defensible reading of what's "current" for
hourly-published observations — but it's soft language ("should"), not a hard rule,
and it's the kind of interpretive question that's genuinely Steve's to weigh rather
than mine to resolve by asserting a reading.

### Not found / would need registration to check further

- **No specific numeric rate limit** appears in the public docs — the FAQ says limits
  are per-service, enforced by blocking the key for the rest of the hour on
  violation, and are non-negotiable. The actual number likely only appears on the
  account dashboard after registering (`bluegull-aqi-8ef.1` already covers getting
  this once we register).
- ~~**No explicit commercial-use clause, no App Store-specific restriction.**~~ —
  **Re-reviewed 2026-07-30** (`bluegull-aqi-8ef.15`), see below.

### Commercial use re-review (bluegull-aqi-8ef.15, 2026-07-30)

Triggered by Steve's decision to pivot the project from non-profit to for-profit,
collecting money via the App Store. The original review's "no explicit commercial-use
clause" gap, harmless for a free/non-profit app, became load-bearing.

**Re-confirmed directly, not just re-asserted**: fetched and read the full text of the
Data Exchange Guidelines PDF, the API FAQ, and the account registration form
specifically searching for commercial-use language. All three are genuinely silent —
not overlooked the first time, actually absent. The guidelines are entirely about data
handling (preliminary-data disclaimer, attribution, non-alteration, notification,
current contact info); the registration form has no organization-type field, no fee
tiers, no commercial/non-commercial distinction.

**New evidence found**: Domo (a commercial BI platform) publishes a supported "AirNow
Connector" as a standard data-source integration. Initially reasoned this was weak
evidence because it's bring-your-own-key — each Domo customer registers their own
AirNow account rather than Domo redistributing under one shared key the way BlueGull
does. Steve pushed back, correctly: that distinction is real architecturally but
doesn't map onto the compliance question. The guidelines' own language ("end users who
receive these data," "products, publications... or any other related distribution")
already contemplates and endorses one-registrant-to-many-end-users redistribution --
that's precisely what the original 2026-07-28 review already established. Domo's
example speaks to a *different*, previously untested axis: whether AirNow tolerates
commercial products building on their API at all. On that axis it's real, on-point
evidence, regardless of key architecture. Whether AirNow data being BlueGull's entire
product (vs. one of Domo's hundreds of interchangeable connectors) matters is a residual
uncertainty worth naming, but nothing in the guidelines' actual text keys off how central
the data is to the product, only how the data itself gets handled -- so it doesn't
appear to be compliance-relevant either.

**Decided (Steve, 2026-07-30): proceed under the existing 2026-07-28 Service-mode
approval, no proactive disclosure of commercial status to AirNow.** The silence plus
the Domo precedent were judged sufficient; `bluegull-aqi-8ef.23` (which would have
updated the `8ef.13` notification to disclose commercial status) is now moot and
closed without action.

### Questions raised for sign-off — and how they resolved

- *Is the FAQ's caching endorsement plus the absence of a prohibition sufficient
  permission for Service mode?* — **Yes.** Reviewed and approved 2026-07-28; caching
  and proxy redistribution proceed.
- *Does the 1-hour cache TTL sit badly with "most current data available"?* — **No.**
  Hourly matches AirNow's own observation publish cadence; the approval covers the
  caching design as specified.
- *Is "make known to... the EPA AirNow program" satisfied by registration, or does it
  warrant returning the acknowledgment form?* — Still an implementation detail rather
  than a blocker; `bluegull-aqi-8ef.13` covers returning the form, which is the more
  conservative reading and cheap to do regardless.
- *Does two-tier attribution need per-reading agency crediting or a generic class
  credit?* — Practically settled by evidence: airnow.gov displays the specific agency
  ("Data courtesy of Bay Area Air District"), so the field exists and the specific
  form is achievable. `bluegull-aqi-10h.15` implements it, with a generic class credit
  as the fallback only where the API supplies no agency.

## AQI Technical Assistance Document & API Fact Sheet — review findings

Reviewed 2026-07-28: [AQI Technical Assistance Document](https://www.airnow.gov/sites/default/files/2020-05/aqi-technical-assistance-document-sept2018.pdf)
(EPA 454/B-18-007, September 2018, 22pp) and the AirNow API Fact Sheet (3pp).

### How much of the TAD actually binds us

Steve's framing is right as to most of it: the TAD is guidance for **local agencies
reporting AQI** under 40 CFR 58.50, not for downstream apps redistributing published
data. The reporting *obligations* — who must report, how often (MSAs >350,000, five
days a week), what a compliant agency report contains — do not apply to us.

**But one part reaches us by incorporation.** The Data Exchange Guidelines, which
*do* bind data recipients, say values "should be disseminated in accordance with the
AQI and corresponding RGB colors **as directed in the Technical Assistance
Document**." That clause pulls TAD **Table 1** (category names and ranges) and
**Table 2** (RGB values) into the document that governs us. So those two tables are
effectively binding-by-reference, while the rest of the TAD is a specification we may
consult but aren't obligated by. *(This is my reading — flagged for Steve, since it
refines his framing rather than simply agreeing with it.)*

### Table 1 + Table 2 — the authoritative values, verbatim

These replace every prior hand-wave about "official EPA colors" in this document.

| AQI range | Descriptor | Color | RGB | Hex |
|---|---|---|---|---|
| 0–50 | Good | Green | 0, 228, 0 | `#00E400` |
| 51–100 | Moderate | Yellow | 255, 255, 0 | `#FFFF00` |
| 101–150 | Unhealthy for Sensitive Groups | Orange | 255, 126, 0 | `#FF7E00` |
| 151–200 | Unhealthy | Red | 255, 0, 0 | `#FF0000` |
| 201–300 | Very Unhealthy | Purple | 143, 63, 151 | `#8F3F97` |
| 301–500 | Hazardous | Maroon | 126, 0, 35 | `#7E0023` |

Two things a naive implementation gets wrong: **Green is `0,228,0`, not `0,255,0`**,
and **Maroon is `126,0,35`**, not a generic dark red. The TAD also gives CMYK values,
irrelevant for screen output.

*Implementation note:* specify these in **sRGB explicitly**. On a wide-gamut Display
P3 Mac, a color literal interpreted in the display's native space would render
noticeably different values than EPA specified.

### "Beyond the AQI" — an edge case our model doesn't handle yet

TAD Table 1 bounds Hazardous at **301–500**. Above 500 is *"Beyond the AQI"*: a value
can still be computed "to indicate relative magnitude," using the Hazardous
breakpoints, and users should "follow the recommendations for the Hazardous category."

*(Correction: an earlier revision of this section claimed airnow.gov diverged from
the TAD by showing "301 +". That was wrong — an artifact of reading a collapsed text
extraction of the legend. The site's expanded AQI Legend panel shows **301–500
Hazardous** plus "Values above 500 are beyond the AQI scale," matching the TAD
exactly. There is no divergence.)*

**Is an AQI above 500 simply bad data?** No — it's rare but real, and EPA treats it as
a defined condition rather than an error:

- The TAD specifies how to compute it ("use the same linear relationship that is used
  for the Hazardous category"), and separately confirms NowCast handles it no
  differently. EPA would not document a computation for a value that could only be a
  fault.
- It has actually happened in official reporting. Oregon DEQ recorded Bend
  [above 500 on 12 September 2020](https://deqblog.com/2020/09/16/wildfire-smoke-brings-record-poor-air-quality-to-oregon-new-data-shows/),
  in their own words "beyond the AQI scale," with Newport "well over 500," during that
  September's wildfires — an AirNow reporting agency publishing such values as
  legitimate.
- We never compute AQI ourselves (`bluegull-aqi-10h.17`), so anything we receive has
  already passed AirNow's own QA. Whether a given reading is trustworthy is upstream
  of us; our obligation is to disseminate as received.

**So the failure mode to design against is the opposite one**: treating >500 as
invalid and rendering a blank, an "unknown" category, or a crash — which would black
out the app precisely during a catastrophic smoke event, the moment it's most needed.
Our category model currently has no representation for >500 at all, so that's the
current behavior by default. Tracked as `bluegull-aqi-10h.16`.

Genuinely malformed values are a separate concern: negative AQI, non-numeric, or
absurd magnitudes indicate a parse or transport fault rather than extreme air, and
should be handled as an error state — distinctly from a legitimate off-scale reading.

### What the number *is*: NowCast, not a spot reading

Both documents are emphatic, and this matters for how we label things:

> "The Air Quality Index is based on daily air quality summaries... **It is not valid
> to use shorter-term (e.g. hourly) data to calculate an AQI value.** However,
> real-time reporting requires shorter-term data... The NowCast is EPA's endorsed
> method for relating short-term data to the Air Quality Index for the purposes of
> real-time reporting."

NowCast uses a **variable averaging window** — longer when air quality is stable,
shorter when it's changing fast (PM2.5: ~12 hours stable, ~3 hours variable; ozone:
~8 hours stable, ~1 hour variable). So the value we display is a weighted average
designed to track lived experience, **not** an instantaneous sensor reading, and not
the daily AQI either. UI copy shouldn't imply otherwise. Tracked as
`bluegull-aqi-10h.18`.

### Hard constraint: never compute AQI ourselves

The TAD supplies the breakpoint table (Table 5) and the linear-interpolation formula
(Equation 1). For this project those are **documentation of what not to do**. The
Data Exchange Guidelines require data be "disseminated as received" without
alteration, and the TAD independently warns that deriving AQI from short-term
concentrations is invalid. So: display AirNow's AQI values as returned; never convert
a concentration into an AQI, never re-derive, never interpolate. If the API returns
raw concentrations for some pollutant without an accompanying AQI, show the
concentration labeled as such — do not compute an index from it. Tracked as
`bluegull-aqi-10h.17`, including a test asserting no AQI derivation exists in the
codebase.

### Endpoint taxonomy (Fact Sheet) — affects which call we actually make

The Fact Sheet enumerates the web services, and the distinctions matter for our
widget's "full pollutant breakdown" scope and for attribution:

- **Current Observations by Reporting Area** — "Real-time air quality observations
  (NowCast AQI) for each pollutant measured by reporting areas – cities or other
  reporting areas **defined by air quality agencies**." This is the one that appears
  to match our needs: NowCast, per-pollutant, and reporting-area-scoped.
- **Observations by Monitoring Site** — site-level rather than aggregated.
- **Forecasts**, **Historical Observations by Reporting Area**, **Contour Maps**
  (AQI-colored spatial polygons) — not v1.

The phrase "reporting areas defined by air quality agencies" is likely where the
agency attribution in `bluegull-aqi-10h.15` comes from — airnow.gov displayed
"San Francisco Reporting Area" and "Data courtesy of Bay Area Air District" together,
consistent with that. Endpoint selection is tracked as `bluegull-aqi-10h.19`.

Also reconfirms the caching posture: file products are recommended "when an AirNow
user needs to extract data across a large time period and/or geographic area" — which
our per-request opportunistic caching is not.

### Smaller findings

- **"Particle pollution" over "particulate matter."** Per EPA focus-group testing,
  "people better understand and prefer the term 'particle pollution.'" A copy
  preference, not a requirement. Tracked as `bluegull-aqi-10h.20`.
- **Sensitive groups (Table 3) and cautionary statements (Table 4)** are required
  content for *agency* reports when AQI > 100, not for us. But the TAD supplies
  authoritative text for both, and this is exactly the health-protective content that
  gives the app its point. Whether v1 or deferred is in Open Questions.
- **EPA distributes its own AirNow app and widget** (TAD Figure 6). Useful prior art,
  and consistent with the earlier finding that EPA's own products are evidence of
  accepted practice rather than a compliance floor.
- **Account activation** requires an emailed confirmation code; the key then appears
  on the Web Services page. Operational detail for `bluegull-aqi-8ef.1`.

## Open questions (blocking or semi-blocking)

- ~~**⛔ Does AirNow's licensing permit Service mode at all?**~~ — **RESOLVED
  2026-07-28, gate lifted.** Reviewed and approved: caching AirNow data and
  redistributing it via a proxy server is permitted. Service mode proceeds alongside
  Direct mode, and all implementation is unblocked (`bluegull-aqi-8ef.10` closed).
  The compliance obligations catalogued in the terms review stand unchanged and gate
  App Store submission — `bd list --label compliance`.
- ~~**How should AQI > 500 ("Beyond the AQI") display?**~~ — **no longer open.** The
  apparent TAD-vs-airnow.gov conflict was my own extraction error; both agree on
  301–500 Hazardous with values above 500 "beyond the AQI scale." Recommended (and
  now reflected in `bluegull-aqi-10h.16`): display the actual value, keep maroon and
  Hazardous health guidance per the TAD's explicit direction, and mark it as beyond
  the scale using AirNow's own phrasing. Left here rather than deleted because the
  real design point survives — the model must not treat >500 as invalid, since that
  blanks the app during exactly the wildfire conditions that produce such readings.
- ~~**Do sensitive-groups and cautionary statements belong in v1?**~~ — **decided
  2026-07-28: deferred past v1.** See "Deferred past v1" below. Deferrable precisely
  because it isn't an obligation on us — TAD Tables 3–4 bind reporting *agencies*
  above AQI 100, not downstream redistributors, so v1 ships compliant without it.
  Tracked as `bluegull-aqi-mtm.16`.
- ~~**Default data-source mode** for a fresh install (Service vs. Direct)~~ —
  **DECIDED 2026-07-30: Service mode.** Works immediately with zero setup (no
  AirNow key needed) for the best first-run experience; the settings UI
  (`bluegull-aqi-e70.3`) lets a user switch to Direct mode (their own key) any
  time. Tracked as `bluegull-aqi-8ef.2`.
- ~~**Domain name** for the backend's custom domain~~ — **DECIDED:** `aqi.bluegull.org`,
  delegated from `bluegull.org`'s DNS at **Squarespace** (registrar; untouched
  otherwise) to a Route53 hosted zone created specifically for the subdomain.
  **Extended 2026-07-30** (`bluegull-aqi-8ef.18`, business-model pivot): a second,
  equivalent delegation added for `aqi.bluegull.solutions`, whose DNS lives at
  **DreamHost** (not Squarespace, unlike `bluegull.org`) — not a replacement, both
  domains stay live.
- ~~**Should stage deployments use subdomain prefixes?**~~ — **DECIDED:** three
  named stacks per domain — prod (`aqi.*`), dev (`dev.aqi.*`), staging
  (`stage.aqi.*`) — all as dot-subdomains under one hosted zone per domain.
  (First-pass hyphenated names `dev-aqi.bluegull.org`/`stage-aqi.bluegull.org` were
  reconsidered once it came up that they're DNS *siblings* of `aqi.bluegull.org`, not
  subdomains, and so couldn't share its hosted zone — would have needed three
  separate delegations instead of one.)
- ~~**AWS account**~~ — **DECIDED:** `843088391598`, dedicated to this project.
- **AirNow API key for the service** — not yet registered; also worth confirming
  AirNow's actual published rate limits/ToS once registering, since that bounds how
  aggressive the DynamoDB cache TTL needs to be.
- **App Group ID / bundle IDs** — not yet created in the Apple Developer portal.

## Phased build order

1. **Backend MVP** — SAM template, single Lambda, DynamoDB cache, stage throttling
   (WAF turned out not to be usable against an HTTP API v2 -- see "Rate limiting"),
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

### Deferred past v1

Explicitly out of scope for the first release — deferred, not rejected. Each is a
live issue at P3/P4 so it resurfaces rather than being lost. Recorded here so the v1
boundary is one visible list instead of scattered across epics:

| Deferred | Issue | Why it's safe to defer |
|---|---|---|
| Sensitive-groups & cautionary statements (health guidance) | `bluegull-aqi-mtm.16` | TAD Tables 3–4 bind reporting *agencies* above AQI 100, not downstream redistributors — v1 ships compliant without it |
| Richer widget detail view (trends, forecast, more pollutants) | `bluegull-aqi-mtm.15` | The v1 tap-to-expand view is deliberately scoped to compliance content only |
| Forecast data | — | The data-scope decision chose current observations only; forecast would be a natural companion to the richer detail view above |
| CloudFront in front of the API | `bluegull-aqi-q9r.33` | Cost/DoS benefit doesn't justify the complexity until real traffic exists |
| App Attest device attestation | `bluegull-aqi-10h.14` | Confirmed supported on macOS 27+, but adopting it means real new server-side verification work and raising the minimum supported OS -- a scope decision, not this v1's default |
| Branch protection on `main` | `bluegull-aqi-8ef.9` | Friction without benefit until CI produces status checks worth gating on |

Note what is *not* on this list: attribution (`e70.10`, `mtm.14`), the
preliminary-data disclaimer (`dc2.4`), official AQI colors, and the never-derive-AQI
constraint (`10h.17`) are all **v1 obligations** and gate App Store submission. The
distinction throughout is between what the AirNow guidelines actually require of us
and what is merely good product.

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

All latency figures are **server-side** — measured from API Gateway receiving the
request to sending the response. Client-observed latency additionally includes DNS,
TLS handshake, and physical distance (a California client hitting `us-east-2` pays
~70ms of round-trip before our code runs), none of which any code change can fix.
Client-observed latency is tracked for UX awareness — target <150ms same-region,
<300ms cross-continent — but never gated.

| Metric | Absolute ceiling | Regression gate |
|---|---|---|
| Warm cached round-trip | p95 < 50ms, p50 < 25ms | 5% |
| Uncached round-trip, AirNow stubbed | p95 < 100ms | 5% |
| Lambda cold start (Init Duration) | p50 < 600ms, investigate > 1s | ~15% |
| p95 latency at 100 concurrent | within 2× the 10-concurrent p95 | 5% |
| Error rate at 10 and 100 concurrent | < 0.1% | 5% |
| Cache hit ratio under steady-state load | > 95% | 5% |

Real end-to-end uncached latency (with a live AirNow call) is tracked as an
observability metric but **not** gated — it substantially measures AirNow's
performance, which we don't control, and gating on it would produce failures we can't
act on.

**Why both an absolute ceiling and a relative gate.** They catch different failures.
The relative gate catches a sudden jump but is blind to the ratchet: drift 4% eleven
times and you've doubled without ever failing a build. The absolute ceiling is what
stops that.

The justification for a *tight* cached-path ceiling is not user experience — the
widget refreshes hourly in the background and nobody is watching a spinner. It's that
latency is the first visible symptom of an access-pattern mistake: a `Scan` where a
`GetItem` belongs, a synchronous call added inside the cache-hit path, serializing
more than the current reading. Those are cheap to catch at 50ms and expensive to find
in production. Where latency does reach the user — first launch and manual refresh —
anything under ~500ms reads as instant, so there is ample margin.

**These ceilings are component-level estimates, not measurements** (~5–10ms API
Gateway HTTP API overhead, ~1–3ms warm invoke, ~8–15ms DynamoDB `GetItem` with a
reused connection). The first dev-stage deploy establishes the real baseline; if
actuals land well under the ceilings, tighten them, because a ceiling carrying 2.5×
slack isn't doing much work.

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

**Resolved (bluegull-aqi-mtm.12): no supported CLI exists.** `WidgetCenter.reloadAllTimelines()`/
`reloadTimelines(ofKind:)`, called from app code, remain the only Apple-supported
reload path -- there's no `xcrun`/`simctl` equivalent for a real Mac's installed
desktop widgets (simctl's widget support is iOS Simulator-only). The one thing
search turned up, `killall NotificationCenter` (sometimes paired with `defaults
delete com.apple.notificationcenterui` first), is a real, commonly-cited fix people
use -- but it's an undocumented, unsupported trick that restarts the whole
Notification Center process system-wide, reloading *every* app's widgets, not
just ours. Not something to build verification tooling around. The actually
useful fact for tightening the manual loop: per Apple's own WidgetKit docs,
running under the Xcode debugger removes the normal reload-rate throttling
entirely, so attaching the debugger to the widget extension during manual testing
is the practical answer, not a CLI.

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

- 2026-07-30 — Implemented bluegull-aqi-e70.3 (settings UI: data-source
  mode toggle). New `DataSourceMode` (`.service`/`.direct`) and
  `DataSourceModeStore` (the UserDefaults key + default-value constants) in
  `BluegullAQIKit` -- `UserDefaults.standard`, not the App Group, since
  this is a container-app-only setting the widget extension never needs
  (it never fetches data itself). `DataSourceModeToggle` in the app target
  is a segmented `Picker` bound via `@AppStorage(DataSourceModeStore.userDefaultsKey)`,
  keyed off the shared constant rather than a duplicated string literal so
  the toggle and whatever eventually reads the setting to pick a client
  (`bluegull-aqi-e70.6`) can't disagree.
  - Deliberately not wired into a settings window/sheet -- none exists yet
    (no gear icon, per `e70.11`'s own scope decision). `e70.4`/`e70.5`
    will each produce their own similarly self-contained piece; composing
    all three into one settings screen is separate, not-yet-tracked
    integration work.
  - Real, minor finding while adding the `ImageRenderer` smoke test (same
    pattern as `e70.11`'s): `.pickerStyle(.radioGroup)` produced an
    "Unable to render flattened version of PlatformViewRepresentableAdaptor"
    warning. Tried `.segmented` instead -- same warning, confirming this is
    a general `ImageRenderer` limitation with native AppKit-backed
    controls (`NSViewRepresentable`) on macOS, not specific to either
    style or a bug in this code. The image still renders (test still
    passes); kept `.segmented` since it's also the better UI fit for a
    binary choice. 2 new package tests (90/90 pass), 1 new app-target
    smoke test (9/9 pass); build and a clean app launch verified.
  - Real, separate bug caught while checking `git status` before
    committing: `.gitignore`'s `*.xcodeproj/xcuserdata/` pattern has a
    slash in the middle, which git anchors to the directory containing the
    `.gitignore` file itself (the repo root) -- it silently never matched
    `mac-app/BluegullAQI.xcodeproj/xcuserdata/` (nested, not at root).
    Latent since `e70.1` first created an actual `.xcodeproj` to test
    against; fixed with an explicit `**/` prefix on both the xcodeproj and
    xcworkspace patterns. Also added a missing `.DS_Store` entry while in
    there.
- 2026-07-30 — Implemented bluegull-aqi-e70.2 (location permission request
  flow). New `LocationPermissionRequester` (app target, not
  `BluegullAQIKit`) -- `LocationResolver`/`SystemLocationProvider`
  deliberately never request authorization themselves, per their own doc
  comments ("permission UX/timing is app-level policy... not this
  package's job"), so this is that missing piece.
  - `@Observable` (Swift's Observation framework, available at the
    macOS 14 minimum), wraps `CLLocationManager`, exposes
    `authorizationStatus` and `requestAuthorizationIfNeeded()` -- a no-op
    unless status is genuinely `.notDetermined`, since CoreLocation itself
    refuses to re-prompt once answered and a denied/restricted status
    needs a System Settings change, not another request call.
    `requestOnInit` defaults to `false` so simply constructing the type
    (a future preview or test) never has the side effect of triggering a
    system dialog; the real app opts in explicitly.
  - Wired into `BluegullAQIApp` with a minimal, real trigger (request on
    launch) -- deliberately not the full "what happens if denied" UX or
    the decision of exactly when current-location mode needs this at all
    (e.g. a user who only ever pins addresses); that orchestration belongs
    to `bluegull-aqi-e70.6`, which depends on this existing at all.
  - Attempted to live-verify past the entitlement barrier that blocked
    Keychain testing earlier this session: found a real code-signing
    identity available locally ("Steve Barber's CA") and tried a properly
    signed build instead of the usual `CODE_SIGNING_ALLOWED=NO` one. Ruled
    out as a real Apple Developer certificate on inspection (self-signed,
    wrong subject format, unrelated email) -- Xcode isn't actually signed
    into Steve's Apple ID in this environment, so this remains genuinely
    blocked on interactive Xcode sign-in, same as Keychain/CoreLocation
    were documented as blocked on earlier (`bluegull-aqi-10h.13`
    /`8ef.5`'s prerequisite chain). Not a new limitation, just the first
    time this session it was worth attempting given real code now exists
    to test against.
  - What was verified: build succeeds, 8/8 tests still pass, and the app
    launches and runs cleanly with `LocationPermissionRequester(requestOnInit:
    true)` actually constructing a real `CLLocationManager` and calling
    `requestWhenInUseAuthorization()` at launch -- no crash despite the
    missing entitlement in this unsigned build, which is itself useful
    information (CoreLocation fails gracefully without entitlements rather
    than crashing the process). The actual system dialog appearing is
    still unverified, same caveat as `SystemLocationProvider` already
    carried.
- 2026-07-30 — Implemented bluegull-aqi-mtm.7 (TimelineProvider unit tests
  using fixture App Group cache state) -- and, along the way, corrected an
  architectural assumption `mtm.2` made without verifying it.
  - Real, confirmed-not-assumed constraint: an `app-extension` build
    product (`BluegullAQIWidget.appex`) isn't a linkable library. A test
    target can `@testable import` it and type-check fine, but the actual
    link step fails outright ("symbol(s) not found for architecture
    arm64") -- unlike an app target, where Xcode's `TEST_HOST`/
    `BUNDLE_LOADER` machinery makes hosted testing work. First tried
    constructing `TimelineProviderContext` directly to call the protocol
    methods; that's also a dead end -- it has no public initializer at
    all, by design, since it represents real host-provided info WidgetKit
    doesn't want test code fabricating.
  - Fixed by moving the actual cache-reading/reload-policy logic into a
    new `BluegullAQIKit.WidgetTimelineComputer` (+ `WidgetTimelineSnapshot`,
    a plain struct -- deliberately not a WidgetKit `TimelineEntry`, same
    "no UI/platform-framework dependency" rationale as `AQIColor`). The
    widget extension's `TimelineProvider` is now a thin wrapper delegating
    to it. This sidesteps the linking problem entirely rather than
    fighting Xcode's extension-hosting configuration, and gives the logic
    a proper home with existing test infrastructure
    (`InMemorySharedCacheStore`) instead of needing its own. 5 new package
    tests; 88/88 pass.
  - Net effect on `mtm.2`'s design (not just where the tests live): the
    reusable computation is now shared-package code like everything else
    genuinely common to both UI targets, rather than being extension-only
    logic that happened to be untestable. Verified via the full test
    suite, a clean build, and a clean app launch with the extension still
    correctly embedded.
- 2026-07-30 — Implemented bluegull-aqi-mtm.2 (widget `TimelineProvider`
  reading the App Group cache). Real logic now, not the `mtm.1` placeholder.
  - Filled a real gap: `AppGroupCache` only had `get(for: Location)`,
    keyed to one specific location -- but there's no per-instance
    location configuration yet (`mtm.3`, App Intents, still open), so the
    provider has no specific location to ask for. Added
    `AppGroupCache.mostRecentEntry()` (the newest still-valid cached
    reading across every location), mirroring `get()`'s expired-entry
    cleanup for consistency with the existing retention-bounding design
    (`10h.12`). Once `mtm.3` lands, a configured instance should prefer
    `get(for:)` with its own pinned location instead. 3 new package tests;
    83/83 pass.
  - The provider's reload policy uses `RefreshScheduler.nextRefreshDate()`
    (built in `10h.10` for exactly this) rather than `.never`, which the
    `mtm.1` placeholder used -- a `TimelineProvider` isn't actually
    correct without a real reload policy, and the scheduler already
    existed purpose-built for it.
  - If the App Group suite can't be opened, degrades to "no data to show"
    (same state as a genuine cache miss) rather than crashing -- a
    deliberate, narrow divergence from `UserDefaultsCacheStore`'s own
    "fail loudly, never silently substitute `.standard`" principle: this
    isn't substituting a different data source, it's treating "cache
    unavailable" as an already-modeled empty state, and a widget extension
    crash is disruptive system-wide in a way a container-app failure isn't.
  - Deliberately did NOT write `TimelineProvider`-specific unit tests here
    -- `bluegull-aqi-mtm.7` ("Add TimelineProvider unit tests using
    fixture App Group cache state") is its own separately tracked,
    dependent issue; duplicating that scope now would preempt work that's
    deliberately split out. The view itself also stays an unchanged
    placeholder (`entry.reading` now genuinely flows through, but
    rendering it is `mtm.4`/`mtm.5`/`mtm.6`'s job, not this one's).
    Verified via build + the full test suite + a clean container-app
    launch with the extension embedded (a widget extension can't be
    launched standalone to verify directly).
- 2026-07-30 — Implemented bluegull-aqi-mtm.1 (scaffold the WidgetKit
  extension target). Second real Xcode target, alongside the container
  app -- `mac-app/project.yml` now has a `BluegullAQIWidget` `app-extension`
  target, embedded into `BluegullAQI` via XcodeGen's `embed: true`
  dependency.
  - `BluegullAQIWidget` bundle ID `solutions.bluegull.aqi.widget`
    (already registered, `bluegull-aqi-8ef.5`), `NSExtensionPointIdentifier:
    com.apple.widgetkit-extension`. Entitlements: App Sandbox + the same
    App Group as the container app (`group.solutions.bluegull.aqi`) --
    deliberately NO network-client or location entitlements, since the
    architecture already decided the widget only ever reads the App Group
    cache and never fetches itself (doc/DESIGN.md "Widget extension
    (WidgetKit)").
  - Placeholder `TimelineProvider`/`Widget`/view only -- a real provider
    reading the App Group cache is separate tracked work
    (`bluegull-aqi-mtm.2`), and per-instance App Intents configuration is
    `mtm.3`. This task was the target/dependency wiring only, matching how
    `e70.1` scaffolded the container app before any real feature work
    landed on it.
  - Real, if minor, bug caught immediately by testing: `import WidgetKit`
    alone wasn't enough for `Widget`/`WidgetBundle` to resolve -- needed
    `import SwiftUI` too. Build failed with "cannot find type 'Widget' in
    scope" until fixed.
  - Verified past "it compiles": confirmed the built `.appex` actually
    lands in `BluegullAQI.app/Contents/PlugIns/` with the correct bundle
    ID and `NSExtension` dictionary, and that the generated entitlements
    file has exactly the intended set (sandbox + App Group, nothing more).
    A widget extension can't be launched standalone the way the container
    app was (it's hosted by the system's widget renderer, not directly
    executable) -- launched the container app instead and confirmed it
    still runs cleanly with the extension embedded, no crash. 8/8
    app-target tests still pass.
- 2026-07-30 — Implemented bluegull-aqi-e70.10 (attribution in the menu bar
  popover). Two-tier attribution per the AirNow Data Exchange Guidelines:
  tier 1 (specific reporting agency, `PollutantReading.attributionText`,
  `bluegull-aqi-10h.15`) shown when available; tier 2 (static AirNow/EPA
  credit) always shown, never omitted -- matches the airnow.gov precedent's
  own structure (a persistent small footer, checked live 2026-07-28).
  - New `AttributionCopy.staticCredit` in `BluegullAQIKit`, not the app
    target -- the widget's tap-to-expand detail view (`bluegull-aqi-mtm.14`)
    needs the identical tier-2 wording, same rationale as
    `PollutantCopy`/`NowCastCopy` already living there to prevent copy
    drift between the two UI targets. Text only, no EPA logo asset (the
    live precedent uses an "EPA and PARTNERS" logo lockup; reproducing
    that as an actual logo image wasn't attempted here).
  - `AQIPopoverView`'s footer credits the *headline* pollutant's reporting
    agency specifically (the same one driving the displayed AQI number,
    via `headlinePollutant` from `bluegull-aqi-e70.11`) rather than
    enumerating every distinct agency across the full pollutant breakdown
    -- matches airnow.gov's own one-agency-per-location-page precedent;
    not attempting to solve the (currently theoretical, not observed on
    live responses) case of different pollutants reporting through
    different agencies in a single reading.
  - Added a render test for the fallback path specifically (reporting
    agency missing -- tier 1 absent, tier 2 alone) alongside the existing
    empty/populated cases, confirming the "never omit tier 2" rule doesn't
    silently break. 8/8 app-target tests and 80/80 package tests pass;
    live app launch clean, no crash.
- 2026-07-30 — Implemented bluegull-aqi-e70.11 (menu bar popover, `.window`
  style). Confirmed the scope boundary against sibling issues first: `e70.6`
  (the status item itself) and `e70.10`/`dc2.4` (attribution/disclaimer
  content) are separately tracked, blocked *by* this one -- so this covers
  the popover's content view (current AQI + full pollutant breakdown) only,
  not compliance text or settings destinations.
  - `AQIPopoverView`: a "dumb" presentational SwiftUI view (`reading:
    AQIReading?`) -- no live data pipeline exists yet (`e70.6`/`e70.7`),
    so `BluegullAQIApp` currently just passes `nil`, showing the empty
    state via `ContentUnavailableView`.
  - Filled a real gap `AQIReading`'s own doc comment explicitly calls out:
    which pollutant's AQI becomes "the" headline number is deliberately
    not the shared model's job. Added `headlinePollutant` (highest
    `nowcastAQI` among entries that have one, matching AirNow's own
    methodology of the worst pollutant driving the reported area AQI) as
    an app-target-only extension, with unit tests for the empty-reading,
    all-nil, and tie-breaking-irrelevant cases.
  - `AQIColor` -> SwiftUI `Color` conversion also lives in the app target,
    not the package, per `AQIColor`'s own doc comment ("no UI framework
    dependency") -- uses the explicit-sRGB `Color(.sRGB, red:green:blue:)`
    initializer, never the ambiguous-color-space default, so the official
    EPA values don't render differently on a wide-gamut Display P3 Mac.
  - Verified past "it compiles" two ways: launched the actual built `.app`
    again (ran cleanly, no crash, no crash report), and -- since the
    popover's content only builds lazily when clicked, which isn't
    otherwise exercisable without UI automation (`e70.9`, not yet built) --
    added a lightweight `ImageRenderer`-based smoke test that actually
    renders `AQIPopoverView` for both the empty and populated states and
    confirms it produces a real image, not just that the view type
    compiles. Deliberately not the full snapshot-testing harness
    (`mtm.10`/`mtm.11`, separately tracked, more elaborate scope for the
    widget) -- just enough to catch a render-time crash in this specific
    view. 7/7 tests pass (`xcodebuild test`).
- 2026-07-30 — Implemented bluegull-aqi-e70.1 (scaffold Xcode project with
  the container app target). First real step into the menu bar app itself,
  distinct from `BluegullAQIKit` (a plain SwiftPM library, no signing/
  entitlements/GUI concerns) -- everything in `mac-app/` before this was
  library code only.
  - No official Apple CLI exists to create a new Xcode project
    non-interactively (the "File > New Project" wizard has no scriptable
    equivalent), and hand-writing `.pbxproj` directly is error-prone
    enough to risk a project that won't open. Used **XcodeGen** instead
    (installed via `brew install xcodegen`, a new local dev-tool
    dependency, not a runtime one) -- `mac-app/project.yml` is now the
    source of truth, `xcodegen generate` regenerates `BluegullAQI.xcodeproj`
    deterministically. The generated `.xcodeproj` is committed (matches
    `.gitignore` already excluding only `xcuserdata/`/`DerivedData/`, not
    the project file itself) so the project opens directly even without
    XcodeGen installed; only `project.yml` needs editing for future
    target/setting changes.
  - `BluegullAQI` target: `MenuBarExtra` app (`.window` style, matching the
    `e70.11` popover decision), `LSUIElement: true` (no Dock icon, matches
    "menu bar app" scope), depends on the local `BluegullAQIKit` package.
    Entitlements: App Sandbox (required for Mac App Store), network client
    (AirNow direct + BlueGull backend calls), location (CoreLocation),
    App Group `group.solutions.bluegull.aqi` (matches `bluegull-aqi-8ef.5`).
    `CODE_SIGN_STYLE: Automatic`, no `DEVELOPMENT_TEAM` hardcoded -- Xcode
    resolves Steve's team on first open rather than baking account-specific
    info into the generated project.
  - `BluegullAQITests` target added per the repo layout `doc/DESIGN.md`
    already specified, with one real (not placeholder) test proving the
    `BluegullAQIKit` link actually works at compile and link time, not just
    that the `import` statement parses.
  - Found and fixed a real config bug via testing, not just review: an
    initial `PRODUCT_NAME: "BlueGull AQI"` (with a space, for a friendlier
    display name) broke the test target's auto-derived `TEST_HOST` path,
    which expected the un-spaced target name -- `xcodebuild test` failed
    with "Could not find test host." Fixed by leaving `PRODUCT_NAME`
    alone and setting `CFBundleDisplayName` in Info.plist instead, which
    doesn't affect build product paths.
  - Live-verified past "it compiles": `xcodebuild build` and `xcodebuild
    test` both succeed (1/1 tests pass), and actually launched the built
    `.app` (`open` + `pgrep`) -- stayed running for 5s with no crash and no
    crash report in `~/Library/Logs/DiagnosticReports/`, then shut down
    cleanly. Real UI (the popover, location flow, settings) is separate
    tracked scope (`e70.11`, `e70.2`, `e70.3`-`e70.5`), deliberately not
    built here -- this issue was the target/dependency wiring only.
- 2026-07-30 — Implemented bluegull-aqi-8ef.5 (create Apple Developer
  bundle IDs and App Group). Registered by Steve in the Developer portal
  (no CLI/API exists for this, unlike the AWS-side work this session):
  `solutions.bluegull.aqi` (container app) and
  `solutions.bluegull.aqi.widget` (widget extension) as explicit App IDs,
  both with the App Groups capability enabled; App Group
  `group.solutions.bluegull.aqi` created and attached to both. Matches the
  naming decided in `bluegull-aqi-8ef.20` and already hardcoded in
  `AppGroupCache.swift`/`AirNowAPIKeyStore.swift` earlier this session, so
  no code changes needed here -- just the account-side registration
  catching up to what the code already assumed. Unblocks
  `bluegull-aqi-e70.1` (scaffold the Xcode project with the container app
  target), the first real step into the menu bar app itself.
- 2026-07-30 — Resolved bluegull-aqi-8ef.22 (verify Apple Developer
  enrollment type fits the for-profit plan): **confirmed Individual,
  proceed under it now.** Steve confirmed the existing membership is
  Individual, not Organization -- the App Store seller name will show his
  personal name, not a company, until converted. Researched whether that's
  a dead end for the eventual "BlueGull Solutions LLC" plan: it isn't.
  Apple's own enrollment docs describe a support-mediated
  Individual-to-Organization conversion path ("please contact us"); the
  fallback is a fresh Organization enrollment plus an App Store Connect
  App Transfer. Both preserve the app's existing reviews, ratings, and
  bundle-ID string -- initially conflated that with the *portal
  registration* of the bundle IDs/App Group and the local Xcode signing
  config, which genuinely are Team-ID-scoped and NOT guaranteed to carry
  over cleanly if a new Team ID is issued (Steve caught this
  inconsistency). Net call: that potential rework is cheap (~10-15 minutes
  of re-registration, routine Xcode re-signing) next to pausing all
  engineering work now, so proceed under Individual and convert later.
  Also worked out *when* "later" actually is: not before more code gets
  written, but before the app actually starts collecting real user
  payments -- an LLC formed today wouldn't retroactively shield anything
  from before it existed, and nothing is live yet, so there's no current
  liability exposure the delay is costing. Unblocks `bluegull-aqi-8ef.5`.
- 2026-07-30 — Implemented bluegull-aqi-8ef.19 (update doc/DESIGN.md's
  bluegull.org references for the new domain). Swept every forward-looking
  reference: the "Backend custom domain" and "AWS region" decisions-table
  rows, the architecture section's "Custom domain" bullet, and the "Open
  questions" resolved-decision bullets for domain name and stage-subdomain
  naming. All now describe **both** domains (added, not migrated, per the
  2026-07-30 pivot decision) rather than only `bluegull.org`, and note the
  Squarespace/DreamHost registrar-vs-DNS-host split for `bluegull.solutions`
  specifically. Historical changelog entries from 2026-07-28 (the original
  domain decision) deliberately left untouched, per this file's established
  convention that changelog entries are historical record, not rewritten.
- 2026-07-30 — Implemented bluegull-aqi-8ef.18 (DNS delegation for
  bluegull.solutions): **confirmed live.** Real infrastructure gap found
  along the way, worth recording: `bluegull.solutions` is registered at
  Squarespace but its actual authoritative nameservers are DreamHost's
  (`dig NS` returned `SOA ns1.dreamhost.com`) -- unlike `bluegull.org`,
  where registrar and DNS host are the same provider. The delegation
  script (`service/bin/setup_route53_domain.sh`) originally assumed
  Squarespace for both domains and would have sent Steve to the wrong
  panel; fixed after he hit `NXDOMAIN` trying to verify and caught the
  mismatch via the SOA record. Fetched DreamHost's own DNS-records docs for
  the correct panel steps. Steve added the NS record in DreamHost's panel;
  `dig NS aqi.bluegull.solutions` now returns the 4 Route53 nameservers.
  `aqi.bluegull.org`'s existing delegation at Squarespace is untouched, per
  the earlier decision to add rather than migrate.
- 2026-07-30 — Resolved bluegull-aqi-8ef.15 (re-review AirNow terms for
  commercial use, P0): **proceed under the existing Service-mode approval,
  no proactive disclosure to AirNow.** Directly re-read the Data Exchange
  Guidelines PDF, API FAQ, and registration form -- all genuinely silent on
  commercial use, confirmed rather than assumed. Found a real data point
  (Domo's commercial "AirNow Connector" product) that initially seemed
  weaker than it was: reasoned its bring-your-own-key architecture made it
  poor evidence, but that conflated an already-resolved question
  (redistribution-under-one-key is fine, per the original 2026-07-28
  approval) with the actually-open one (is commercial use tolerated at
  all). Corrected after Steve pushed back on the distinction. See "AirNow
  terms review" > "Commercial use re-review" for the full writeup. Closes
  `bluegull-aqi-8ef.23` (AirNow notification's commercial-status
  disclosure) as moot -- no disclosure happening, so nothing to update
  there.
- 2026-07-30 — **Business model pivot**: Steve decided to change this from a
  non-profit project to a for-profit one, collecting money via the App
  Store to cover infrastructure costs with flexibility to eventually pay
  himself for ongoing operations. Two immediate, concrete decisions came
  out of it, both closing bd issues opened to track the ripple effects
  (`bluegull-aqi-8ef.15`-`8ef.23`):
  - **Domain**: switching from `bluegull.org` to `bluegull.solutions`
    (already owned, registered at Squarespace -- same registrar as
    `bluegull.org`). The existing live `aqi.bluegull.org` -> Route53
    delegation (confirmed live 2026-07-28) stays as-is; a new delegation
    for the new domain gets added alongside it, not migrated. DNS/AWS work
    itself tracked in `bluegull-aqi-8ef.18`, not done yet.
  - **Bundle ID / App Group naming**: `solutions.bluegull.aqi` (container
    app), `solutions.bluegull.aqi.widget` (widget extension), App Group
    `group.solutions.bluegull.aqi` -- replacing the `org.bluegull.aqi`
    placeholder that matched the old domain's TLD. Worth a correction for
    the record: initially reasoned that `.solutions` "doesn't map as
    cleanly" via reverse-DNS as `.org` did -- Steve rightly pushed back.
    `.solutions` is a legitimate, ICANN-recognized gTLD; the reverse-DNS
    mapping is exactly as mechanically clean either way. The real (much
    narrower) distinction is just that `.solutions` is a newer gTLD than
    legacy ones like `.com`/`.org`, so fewer bundle IDs "in the wild" use
    anything but those -- a familiarity/convention point, not a
    correctness one, and not worth overstating. Updated the three places
    that had the old placeholder baked in:
    `AppGroupCache.swift`'s `appGroupIdentifier`,
    `AirNowAPIKeyStore.swift`'s Keychain `service` string, and the test
    suite name in `UserDefaultsCacheStoreTests.swift`. 79/79 tests still
    pass.
  - Still open and tracked: re-reviewing the AirNow Data Exchange
    Guidelines specifically for commercial/monetized use
    (`bluegull-aqi-8ef.15`, P0 -- the original 2026-07-28 terms review
    explicitly left "no explicit commercial-use clause" unresolved, and
    that gap is now load-bearing), the business entity/structure decision
    (`8ef.16`), the actual DNS/AWS delegation work (`8ef.18`), updating
    every `bluegull.org` reference in this document (`8ef.19`), verifying
    the Apple Developer Program enrollment type fits (`8ef.22`), and
    updating the AirNow notification's scope to disclose commercial status
    before it's sent (`8ef.23`).
- 2026-07-30 — Implemented bluegull-aqi-8ef.11 (AWS Budget alarms before
  first deploy), in account 843088391598 (bluegull-aqi-8ef.4). Real AWS
  account changes, so run by Steve from his own terminal rather than from
  this agent's sandboxed shell -- the `aws` CLI here is shimmed through
  1Password (`op plugin run`), which isn't unlocked in a non-interactive
  session. `service/bin/setup_budget_alarms.sh` captures the steps and is
  idempotent (safe to re-run; checks for existing resources before
  creating).
  - **Budget**: `bluegull-aqi-monthly-cost-guard`, $10/month COST budget,
    notifying `sbarber2@gmail.com` at ACTUAL 50%, ACTUAL 100%, and
    FORECASTED 100%. Verified via `describe-budget` and
    `describe-notifications-for-budget`.
  - **Cost Anomaly Detection**: found the account already had an
    AWS-auto-provisioned `Default-Services-Monitor` (DIMENSIONAL/SERVICE,
    predates this project -- created 2025-02-06) with its own
    `Default-Services-Subscription`, but that subscription only fires on a
    combined $100 AND 40% anomaly -- too coarse for an account whose
    baseline spend should be near zero. Reused the existing monitor rather
    than creating a redundant one, and added a second, separate
    subscription (`bluegull-aqi-cost-anomaly-alerts`) at a $1 absolute
    threshold instead of modifying the pre-existing account-level default.
    Verified via `get-anomaly-monitors`/`get-anomaly-subscriptions`;
    `Subscribers[0].Status` came back `CONFIRMED` immediately (the email
    address was already verified account-wide via the pre-existing
    subscription, so no fresh confirmation click was needed this time).
  - Cost Explorer/Anomaly Detection's API only exists at the `us-east-1`
    endpoint regardless of which region resources actually run in -- same
    quirk as IAM/Route53/ACM-for-CloudFront -- but the DIMENSIONAL/SERVICE
    monitor tracks costs account-wide across all regions, so this still
    fully covers the `us-east-2` deploy target.
  - Real gap found and fixed along the way: the budget itself already
    existed in the account (from an earlier attempt during this same
    session, cause not fully diagnosed) but with **zero notifications
    attached** -- `describe-notifications-for-budget` came back empty even
    though the budget's limit/type were correct. Added the three
    notifications via `create-notification` against the existing budget
    rather than via `create-budget` (which can't be reused once a budget
    exists). The rewritten script now checks for this specific
    partially-created state (budget exists, notification count is 0) and
    fixes it rather than assuming "budget exists" means "fully configured."
- 2026-07-30 — Resolved bluegull-aqi-10h.14 (investigate App Attest on native
  macOS) and bluegull-aqi-mtm.12 (investigate a widget-reload CLI). Both
  research-only, no code changed.
  - **App Attest**: yes, supported as of macOS 27 (previously it wasn't --
    `isSupported` reliably returned false on native macOS even with a Secure
    Enclave). Found the extension-type restriction (only main app, Action,
    and SSO extensions -- not WidgetKit extensions) doesn't actually matter
    for this project, since the widget extension already never makes its own
    network calls (the container app owns all networking, per the existing
    architecture). Also found App Attest requires full security mode + SIP
    on macOS specifically, so it can never be assumed universally available
    even on a qualifying OS. Wrote up the adoption sketch the task asked
    for (client: key generation + attestation ceremony + per-request
    assertions in the main app; server: new verification logic in
    `lambda_handler.py` against Apple's root cert chain, plus replay
    tracking via signature counters, most naturally in the existing
    DynamoDB table) -- a real feature with a real macOS-27-floor cost, left
    as a future candidate rather than undertaken now. Corrected
    doc/DESIGN.md's "Unverified" section and the deferred-work table
    accordingly.
  - **Widget-reload CLI**: no supported one exists. `WidgetCenter.reloadAllTimelines()`/
    `reloadTimelines(ofKind:)` from app code remain the only Apple-sanctioned
    path; `simctl`'s widget support is iOS-Simulator-only, nothing
    equivalent exists for a real Mac's installed widgets. Found the
    commonly-cited `killall NotificationCenter` trick, but it's undocumented,
    unsupported, and restarts every app's widgets system-wide -- not
    something to build verification tooling around. The practically useful
    finding instead: Apple's own docs confirm the debugger removes the
    normal reload-rate throttling entirely, so attaching Xcode's debugger to
    the widget extension during manual testing is the real answer to
    tightening that loop.
- 2026-07-30 — Resolved bluegull-aqi-q9r.5 (add WAFv2 rate-based rule) and
  bluegull-aqi-q9r.34 (verify WAF rate-based rule minimums) as not viable,
  without writing any WAF resources into template.yaml. Before implementing,
  checked AWS's current CloudFormation docs for `AWS::WAFv2::WebACLAssociation`
  and found its `ResourceArn` only accepts an Application Load Balancer, an
  API Gateway **REST** API, AppSync, Cognito, App Runner, Verified Access, or
  Amplify -- HTTP API (v2), what `AqiHttpApi` actually is, isn't in that list
  and isn't supported. The task as originally scoped (attach WAF directly to
  the existing HTTP API) was never achievable with the current architecture,
  contradicting what doc/DESIGN.md's "Rate limiting" section had said.
  Surfaced the fork to Steve rather than guessing at an architecture change
  (REST API migration, pulling CloudFront/q9r.33 forward, or dropping WAF) --
  decided to drop WAF and rely on what's already in place: API Gateway stage
  throttling (q9r.31), Lambda reserved concurrency (q9r.31), and the new
  cache-miss budget (q9r.32). None of those are per-IP, so a single
  misbehaving client can still exhaust the shared budget for everyone -- an
  accepted tradeoff at this scale, not an oversight. Corrected every prior
  DESIGN.md reference to WAF-on-the-API-Gateway accordingly (the decisions
  table, "Rate limiting", "Denial of wallet", "Deliberately out of scope",
  the phased build order) and template.yaml's header comment. CloudFront
  remains the noted future path back to WAF if true per-IP throttling turns
  out to matter later (it does support CloudFront distributions directly).
  Incidentally answered q9r.34's own question while researching this even
  though it's now moot: AWS WAFv2's `RateBasedStatement.Limit` has a minimum
  of 10 and max of 2,000,000,000; `EvaluationWindowSec` allows 60/120/300/600
  seconds, default 300 -- kept here for reference if CloudFront+WAF happens
  later. No code changed; `sam validate --lint` and `sam build` both still
  succeed against the corrected template header.
- 2026-07-30 — Implemented bluegull-aqi-q9r.25 (gate module import time and
  package size locally, an AWS-free cold-start proxy). New
  `bin/coldstart_gate.py`, wired into `service-ci.yml` right after `make
  build`: measures `import bluegull_aqi_service.lambda_handler` time in a
  fresh subprocess (a warm interpreter's import cache would hide the real
  cost, and Lambda's Init always starts cold) and the actual byte size of
  `.aws-sam/build/AqiFunction`, failing the build if either exceeds a
  ceiling. Both are measurable without any deployment and correlate well
  with Init Duration, so this catches the most common cold-start regression
  -- someone adding a heavy dependency -- on every PR, long before the
  nightly perf run against a real deployed Lambda (bluegull-aqi-q9r.24,
  still open) ever would.
  - Ceilings (350ms import, 50MB package) are generous placeholders with
    headroom over locally-measured baselines (~90-120ms, ~21MB), not tuned
    targets -- meant to be re-tightened once real Init Duration
    measurements exist (bluegull-aqi-q9r.26). Overridable via
    `MAX_IMPORT_TIME_MS`/`MAX_PACKAGE_SIZE_MB` for local experimentation.
  - `import time -X importtime` showed the import cost is almost entirely
    boto3 (and s3transfer specifically, imported unconditionally as part of
    boto3's own package init even though this service never touches S3) --
    consistent with the bluegull-aqi-q9r.18 decision to keep vendoring
    boto3 rather than chase a runtime-provided copy that isn't reliably
    documented for this project's runtime. Switching from the high-level
    `boto3` package to bare `botocore` clients would likely cut this
    further, but that's a separate, more invasive change than this issue
    asked for -- noted here as a candidate, not undertaken.
  - Verified the gate actually catches a regression, not just that it
    passes today: ran it with `MAX_IMPORT_TIME_MS=1` and separately
    `MAX_PACKAGE_SIZE_MB=1`, confirmed both fail loudly with a nonzero exit
    and a clear message, then confirmed a normal run passes.
- 2026-07-30 — Implemented bluegull-aqi-q9r.18 (minimize Lambda cold start:
  package size and client init), partially.
  - **Client init**: `cache.resolve_table()` (the DynamoDB Table resource
    used by both `Cache` and the new `MissRateLimiter`) is now memoized at
    module scope, keyed by table name -- built once and reused across every
    warm invocation, instead of a fresh `boto3.resource("dynamodb").Table(...)`
    on literally every single request (`Cache()` and now `MissRateLimiter()`
    are both instantiated fresh per `get_aqi()` call). `_resolve_airnow_api_key()`
    already did the equivalent for the SSM client/resolved key, so this
    closes the one remaining gap. All 68 tests still pass; no observable
    behavior change, just fewer redundant client constructions per warm
    invocation.
  - **Package size**: deliberately *not* done, after investigating and
    surfacing the tradeoff for a decision rather than guessing. The issue's
    "prefer the runtime-provided boto3 over vendoring a copy" would shrink
    the ~27MB deployment package meaningfully, but the clearest current AWS
    guidance found (an AWS Compute Blog post on the Python SDK in Lambda)
    explicitly recommends bundling all dependencies, including the SDK,
    specifically because the runtime-provided version can change without
    warning -- and there was no way to verify either way for this project's
    python3.14 runtime specifically (no Docker available locally to inspect
    the base image, and no live deploy to test against, per the standing
    no-AWS-actions-without-permission boundary). Decided, with Steve's
    input, to keep vendoring boto3 rather than risk an ImportError
    discovered only at the first real deploy (q9r.10, still open). Revisit
    if/when there's a way to verify against the actual runtime.
- 2026-07-30 — Implemented bluegull-aqi-q9r.32 (rate-limit cache misses
  separately from overall request rate): the stronger version of the
  cache-cardinality defense in "Cache-cardinality attack" above, on top of
  coordinate validation (bluegull-aqi-q9r.30) and grid-snapping
  (`cache.LOCATION_KEY_PRECISION`), which only bound *where* an attacker can
  force a miss, not *how many* misses actually reach AirNow.
  - New `rate_limiter.MissRateLimiter`: a single global budget (not
    per-location or per-IP -- AirNow enforces its own limit per service key,
    so that's the dimension that actually matters), tracked as one counter
    item per fixed wall-clock window in the same DynamoDB table `Cache`
    already uses (a second on-demand table would double the billing surface
    for no benefit at this scale). `consume()` is a single conditional
    `UpdateItem` (`ADD MissCount :one` gated on `MissCount < :budget`), the
    same atomic-under-concurrency pattern as `Cache.try_acquire_refresh_lock()`
    -- verified directly with a 20-thread race against a budget of 5,
    asserting exactly 5 successes.
  - Wired into `aqi_lookup._fetch_fresh_observations()`, the one chokepoint
    every real AirNow call passes through -- a request resolved by a cache
    hit, a stale-serve, or another request's in-flight refresh never reaches
    it, so only calls that would actually cost quota consume budget. The
    stub load-test path (bluegull-aqi-q9r.20) is exempted entirely, same as
    it already skips API key resolution.
  - Budget-exhausted is treated exactly like an AirNow failure in
    `_refresh()`: serve stale if there's a value on hand, otherwise propagate
    a new `RateLimitExceededError`. `lambda_handler.py` maps that to HTTP
    429 with a generic message -- never the internal budget/window numbers.
  - Default budget (400/hour) is a placeholder, not a measured value --
    AirNow's real per-key limit isn't published and only appears on the
    account dashboard after registering (bluegull-aqi-8ef.1). Both the
    budget and window are SAM Parameters (`MissRateLimitBudget`,
    `MissRateLimitWindowSeconds`) specifically so they can be retuned later
    without a code change. Window defaults to 3600s to match AirNow's own
    FAQ-documented enforcement cadence ("blocked for the rest of the hour"
    on violation) -- self-throttling on the same cadence means the service
    backs off before AirNow ever has to.
  - Live-verified over real HTTP against `run_local.py` + real DynamoDB
    Local (not just pytest): confirmed the stub path never touches the
    limiter, then with `MISS_RATE_LIMIT_BUDGET=1` confirmed a cache miss at
    one location consumes the only unit of budget (502 upstream failure,
    fake key) and a *different* location immediately gets 429 without any
    upstream attempt -- proving the budget is actually global, not
    accidentally scoped per `LocationKey` the way the refresh lock is.
    Incidentally caught the shared counter's realism firsthand: an earlier
    smoke-test request against the persistent local table returned 429
    immediately because the pytest run moments before had already spent
    part of the same real-hour window's default budget -- correct behavior
    for a global counter, not a bug, but a reminder the budget is one
    shared resource across every caller, tests included.
  - 68/68 backend tests pass (`make pytest`); `make lint`, `sam validate
    --lint`, and `sam build` all clean.
- 2026-07-30 — Implemented bluegull-aqi-q9r.7: `.github/workflows/service-ci.yml`
  runs lint, pytest, `sam validate`, and `sam build` on every push and PR,
  mirroring Plant-Tracer's `ci-cd.yml`. No AWS account or deployment needed
  -- DynamoDB Local starts automatically via the existing pytest session
  fixture, and `sam build`'s native Python build method doesn't need
  Docker. Verified action versions directly against GitHub's release API
  (`gh release list`) rather than trusting a web search snippet, which
  turned out to already be citing a stale `actions/checkout@v6` example --
  actual latest is v7.0.1; also bumped the existing `secret-scan.yml`'s
  `actions/checkout@v4` to `@v7` for consistency while in there. No local
  GitHub Actions runner available (`act`/`docker` not installed) to fully
  dry-run the workflow, so pushed it and watched the real run via `gh run
  watch`: all steps passed in 51s, including DynamoDB Local + pytest
  (confirming Java is available on `ubuntu-latest` without an explicit
  setup step) and `sam build` (confirming the native, container-free build
  works on the runner).
- 2026-07-30 — Implemented bluegull-aqi-10h.20: `PollutantCopy.spelledOutName(forParameterName:)`
  provides "Particle Pollution (PM2.5)"/"Particle Pollution (PM10)" -- the
  TAD FAQ: "Based on focus group testing by EPA, people better understand
  and prefer the term particle pollution than particulate matter." Falls
  back to the raw `parameterName` unchanged for any other pollutant --
  deliberately narrow scope, no invented translation table for pollutants
  this issue never asked about. Added a `ComplianceTests` guard (matching
  the 10h.17/10h.18 pattern) forbidding "particulate matter" anywhere in
  `Sources/`, verified it actually catches a violation via temporary
  injection. 79/79 tests pass via `swift test`.
  - `RefreshScheduler` derives a stable per-install offset within the
    refresh interval (persisted via `SharedCacheStore`, so the container
    app and widget extension see the same schedule) and computes the next
    refresh time on that install's interval-spaced schedule -- spreading
    load across all installs instead of every one waking at the top of the
    hour and synchronizing into a server-side spike. The offset is
    generated once and persisted, not regenerated per call, so the refresh
    interval stays consistent rather than becoming irregular.
  - Found and fixed a real floating-point precision bug via testing, not
    just logic review: the initial implementation computed the next
    boundary as a raw `Double` and checked it was "strictly after now"
    using `timeIntervalSince1970` values directly -- but `Date` stores time
    relative to 2001, not 1970, and converting a ~1.7-2 billion-second
    "seconds since 1970" value into that internal representation loses some
    low-order precision. Two raw pre-conversion Doubles that looked safely
    different could land on the exact same `Date` after conversion, making
    `next > now` fail intermittently for `now` values landing near a
    computed boundary -- caught by a flaky test (3-4 failures per 10 runs,
    not deterministic), root-caused with an isolated repro script rather
    than guessed at, and fixed by doing the "strictly after" check and any
    necessary bump entirely in `Date`'s own domain (comparing already-
    constructed `Date` values and using `addingTimeInterval`) instead of
    mixing pre- and post-conversion `Double` representations.
  - Verified with 30 consecutive runs of the specific test after the fix,
    then 3 full-suite runs. 75/75 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.12 (bound App Group cache
  retention and review file protection). Found a real gap first: the
  original `AppGroupCache.get()` (from `bluegull-aqi-10h.7`) treated an
  expired entry as a miss but never actually deleted it, so stale entries
  accumulated forever -- and since cleanup only happened reactively on a
  `get()` for that exact key, a location the user never revisits (e.g.
  current-location mode while traveling, or one-off resolved addresses)
  would never get cleaned up at all. Fixed with two bounding mechanisms:
  - Expired entries are now deleted, not just skipped -- reactively on
    `get()`, and proactively across *every* stored entry on each `put()`
    (the cache is only ever written right after a successful fetch, which
    is also the natural, cheap place to sweep it).
  - A hard cap on entry count (`maxRetainedEntries = 10`, generous relative
    to the realistic use case of current-location plus a handful of pinned
    favorites): if still over the cap after sweeping expired entries, the
    oldest-by-`fetchedAt` are evicted. TTL alone only bounds *age*, not
    *count*.
  - `SharedCacheStore` gained `allKeys()` so `AppGroupCache` can enumerate
    and sweep its own entries (filtered by its `aqi-cache-` prefix, so a
    store shared for other purposes is left alone).
  - File protection: verified against Apple's own Security Guide that
    macOS has no per-file Data Protection classes the way iOS does --
    Class A on macOS is backed by the FileVault *volume* key, not a
    per-file key, and Class D ("No Protection") is "Not supported in
    macOS." There's no per-file protection-class API call to make here;
    the actual data-at-rest protection this depends on is FileVault
    (system-level, user-controlled), not something this package configures.
    Documented this conclusion directly in `AppGroupCache`'s doc comment
    rather than leaving it silently unaddressed.
  - Retention bounding verified against both the in-memory fake (7 new
    tests) and the real `UserDefaults` API (2 new tests) -- not just the
    fake, matching this cache's existing test approach. 68/68 tests pass.
- 2026-07-30 — Reviewed bluegull-aqi-10h.13 (Keychain item accessibility and
  access group): `SystemKeychain`'s accessibility (`kSecAttrAccessibleAfterFirstUnlock`,
  not the deprecated/insecure `.always`) and sync (`kSecAttrSynchronizable
  = true`) were already correct from `bluegull-aqi-10h.5`. The access-group
  question was the real review: concluded no shared `kSecAttrAccessGroup`
  should exist, since only the container app ever needs the raw AirNow key
  -- the widget extension only reads pre-fetched AQI data from
  `AppGroupCache` (`bluegull-aqi-10h.7`), never the key itself. No group
  means the item defaults to the narrowest possible scope (this app alone).
  Documented the reasoning in `SystemKeychain`'s doc comment and added a
  `ComplianceTests` guard so a shared access group can't be added later
  without deliberately revisiting this conclusion. 62/62 tests pass.
- 2026-07-30 — Implemented bluegull-aqi-10h.11: `Location.rounded` rounds to
  ~1km precision (2 decimal degrees), deliberately matching the server's own
  `LOCATION_KEY_PRECISION` in `cache.py` exactly -- same grid on both ends
  maximizes cache-hit-rate alignment, not just privacy. `AirNowDirectClient`
  now rounds before building the request, so AirNow never receives a
  precise coordinate regardless of what precision the caller passed in; the
  returned `AQIReading.location` is the rounded value too, since that's
  what was actually requested. `BluegullServiceClient` (`bluegull-aqi-10h.4`,
  not yet built) will need the same treatment -- added a note on that issue
  so it isn't missed. Updated two existing `AirNowDirectClientTests` that
  asserted exact unrounded coordinates in the request/response, and added a
  new `LocationTests` case confirming rounding actually rounds (not
  truncates) using a value exactly on a .5 boundary. 61/61 tests pass via
  `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.7: `AppGroupCache`, a
  location-keyed AQI cache (1-hour default TTL) meant to be shared between
  the container app and widget extension via an App Group -- written by the
  container app after a successful fetch, read by the widget's
  TimelineProvider.
  - `UserDefaultsCacheStore` sits behind a `SharedCacheStore` protocol.
    Unlike `SystemKeychain`/`SystemLocationProvider`/`SystemAddressGeocoder`
    elsewhere in this package, this one IS tested directly against the real
    `UserDefaults` API (5 tests, using a distinct test-only suite name,
    cleared in setUp/tearDown) -- confirmed empirically first that
    `UserDefaults(suiteName:)` works fine even without a real registered
    App Group entitlement (it's just a local plist-backed suite until
    cross-process sharing is actually exercised), unlike Keychain/
    CoreLocation which both hard-failed without one. What's still
    unverified is the actual cross-process sharing this exists for -- that
    needs the real container app and widget extension wired together with
    a real App Group (`bluegull-aqi-8ef.5`).
  - `init?(suiteName:)` deliberately doesn't silently fall back to
    `.standard` if the suite fails to open -- that would mean the container
    app and widget silently stop sharing data instead of failing loudly.
  - 7 additional logic tests (TTL boundaries, malformed-data-is-a-miss,
    location independence) run against an in-memory fake with a
    controllable `now`, so expiry behavior doesn't depend on real wall-clock
    timing.
  - 58/58 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.6: `LocationResolver` handles
  both supported location modes -- current GPS location
  (`SystemLocationProvider`, wraps `CLLocationManager.requestLocation()` via
  the classic delegate pattern bridged to async/await, deliberately not the
  newer `CLLocationUpdate.liveUpdates()` API given a documented Apple Forums
  crash report combining it with authorization requests, not fixed until
  iOS/macOS 18) and a user-pinned address/zip
  (`SystemAddressGeocoder`, wraps `CLGeocoder`) -- no backend geocoding
  endpoint needed. Both sit behind injectable protocols
  (`LocationProvider`/`AddressGeocoder`) exactly as the issue asked: CI
  can't exercise real GPS or live geocoding, so all 6 tests use fakes.
  Neither real implementation is verified live -- didn't even attempt it
  this time, since `bluegull-aqi-10h.5`'s Keychain work hit the identical
  entitlement/signing barrier moments earlier in this same session (a bare
  Swift package test target isn't a signed, entitled app bundle, and
  CoreLocation's authorization flow needs both). Real verification waits
  for the same things: `bluegull-aqi-8ef.5` (Apple Developer account) and
  an actual app target. 46/46 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.5: `AirNowAPIKeyStore` reads,
  writes, and deletes the user's own AirNow API key (Direct mode) as an
  iCloud-synced Keychain item (`kSecAttrSynchronizable`, so it follows the
  user across their Macs).
  - `SystemKeychain` (the real `SecItem*`-backed implementation) sits
    behind an injectable `KeychainStore` protocol, so `AirNowAPIKeyStore`'s
    logic is fully unit-testable (10 tests) against an in-memory fake --
    deliberately never the real macOS Keychain from automated tests, since
    a bare `swift test` process isn't a signed, entitled app bundle and
    touching real persistent keychain state from a test run risks leaving
    artifacts behind or failing outright.
  - Confirmed that last part live: asked first, then tried a one-off
    executable target calling `SystemKeychain` directly against the real
    keychain. First attempt failed with `errSecMissingEntitlement`
    (-34018); a second attempt with an ad-hoc-signed
    keychain-access-groups entitlement got killed outright by the OS. Real
    verification of `SystemKeychain`'s actual `SecItem*` calls needs a
    properly signed, provisioned app target -- not available until
    `bluegull-aqi-8ef.5` (Apple Developer bundle IDs, an account action
    requiring Steve) and the settings UI (`bluegull-aqi-e70.4`) exist. The
    code matches the documented API contract and the standard, widely-used
    shape for this exact pattern, but is unverified against the real
    system until then -- flagged explicitly rather than claimed as tested.
    Temporary verification target removed before committing either way.
  - 40/40 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.3: `AirNowDirectClient` calls
  AirNow's `current/ziplatlong` endpoint directly (the same endpoint the
  backend service uses, confirmed in `bluegull-aqi-10h.19`), returning an
  `AQIReading`. Takes the API key as a parameter rather than reaching into
  Keychain itself -- keeps the client testable in isolation and decoupled
  from `bluegull-aqi-10h.5` (not built yet); whatever wires the two together
  is a later task's job. New `AirNowError` mirrors the Python client's error
  handling: checks for AirNow's `{"WebServiceError": [...]}` body regardless
  of HTTP status (AirNow returns some errors, e.g. "no observations for this
  location," with a 200), and an empty array is valid data, not an error.
  All 7 unit tests mock the network via a custom `URLProtocol` (no live
  AirNow traffic in the automated suite, matching the Python client's own
  approach) -- including one confirming the API key never appears in a
  thrown error's description. Beyond the mocked tests, also verified live
  against the real AirNow API end-to-end: temporarily added an executable
  target calling the real endpoint with the real key (via 1Password),
  confirmed correct AQI values/categorization/attribution for a real
  location, then removed the target before committing -- it was a one-off
  verification tool, not part of the package. 34/34 tests pass via
  `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-q9r.14: added realistic, full-shaped
  API Gateway HTTP API (payload format 2.0) event fixtures
  (`tests/fixtures/api_gateway_event*.json`), verified against AWS's own
  documented example rather than a hand-built minimal dict, and
  `test_lambda_handler_contract.py` exercising `lambda_handler` against them
  -- so the thin-handler-over-core-logic split is verified against what API
  Gateway actually sends, not just structurally. The missing-params fixture
  deliberately omits `queryStringParameters` entirely (matching API Gateway
  v2's real behavior for a request with no query string -- it doesn't send
  an empty dict), which the handler's existing `event.get(...) or {}`
  already handled correctly. Closed bluegull-aqi-q9r.9 (unit/integration
  tests for the Lambda handler) as already satisfied by the test suite built
  up over today's session -- 59 tests, all against real DynamoDB Local
  (never mocks/moto), no AWS account needed. 59/59 tests pass, pylint 10.00/10.
- 2026-07-30 — Fixed Dependabot alert #1 (GHSA-6w46-j5rx-g56g / CVE-2025-71176,
  medium severity): pytest < 9.0.3 has vulnerable `/tmp/pytest-of-{user}`
  handling on UNIX. Surfaced within minutes of enabling Dependabot security
  updates (`bluegull-aqi-8ef.12`, same session) -- confirming it actually
  works. Dev-only dependency (not in the deployed Lambda), but a cheap,
  low-risk fix: bumped `pytest = "^8.0"` to `"^9.0.3"` in `pyproject.toml`,
  re-locked (8.4.2 -> 9.1.1). 57/57 tests pass under the new version, pylint
  10.00/10, `sam validate --lint` clean.
- 2026-07-30 — Implemented bluegull-aqi-10h.18: `NowCastCopy.headline`
  ("Current Air Quality" -- airnow.gov's own phrasing, verified safe) for UI
  code to use instead of inventing wording that implies an instantaneous
  spot reading, which AirNow's NowCast AQI values are not. Added a
  `ComplianceTests` guard (matching the pattern from bluegull-aqi-10h.17)
  scanning `Sources/` for exactly the phrases the issue calls out as unsafe
  ("right now", "current reading", etc.) so this can't regress silently.
  Verified the guard actually catches a violation (not just that it passes
  today) by temporarily injecting one, confirming failure, then restoring.
  Deliberately did not define a longer NowCast explanation string here:
  placement and wording for a detail/expand view are UI decisions for
  whichever task actually builds that view (`bluegull-aqi-e70.11`,
  `mtm.14`), not this shared package's job. 27/27 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-8ef.12: enabled Dependabot security
  updates on `sbarber2/bluegull-aqi` (confirmed disabled on 2026-07-27), via
  `gh api -X PUT /repos/sbarber2/bluegull-aqi/vulnerability-alerts` and
  `.../automated-security-fixes` -- confirmed with the user first since this
  is a repo *settings* change via the GitHub API, a different category from
  the file/commit permission already granted. Verified via
  `security_and_analysis.dependabot_security_updates.status == "enabled"`.
  Covers both the Lambda's Python dependencies and BluegullAQIKit's Swift
  dependencies once those exist. `secret_scanning_non_provider_patterns` and
  `secret_scanning_validity_checks` remain disabled -- separate P3 issue
  `bluegull-aqi-8ef.8`, not in scope here.
- 2026-07-30 — Implemented bluegull-aqi-10h.15: `PollutantReading.attributionText`
  produces "Data courtesy of {reportingAgency}" -- the first tier of the
  two-tier attribution the AirNow Data Exchange Guidelines require (credit
  FIRST to the specific state/local/tribal agency, THEN to AirNow/EPA). The
  second, static EPA/AirNow branding tier is app-level UI content
  (`bluegull-aqi-e70.10`/`mtm.14`), not this package's job. Also made
  `reportingAgency` optional (`String?`, was `String`) since AirNow's
  contract doesn't guarantee it for every location even though it's been
  present on every live-tested response so far -- `attributionText` returns
  nil when missing or blank, and the fallback in that case is simply to show
  only the second (static) tier rather than inventing a placeholder agency
  name. 25/25 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-10h.16: fixed a real conflation bug
  bluegull-aqi-10h.2's original `AQICategory.init(aqi:)` had introduced --
  a negative AQI value (malformed data, a parse/transport fault) fell
  through the same `default:` case as `> 500` (a real, valid "beyond the
  scale" reading), silently misclassifying corrupted data as extreme air
  quality. `init(aqi:)` is now failable (`init?`), returning nil for a
  negative value so the caller must treat it as an error state, while a
  genuine `> 500` value still correctly produces `.beyondAQI` --
  `PollutantReading.category` updated to `flatMap` accordingly. Added
  `AQICategory.isBeyondScale` and `.beyondScaleNotice` (AirNow's own
  verbatim phrasing, "Values above 500 are beyond the AQI scale" --  not
  invented wording) so UI code can surface the distinction. Deliberately did
  NOT add upper-bound "implausibly large" detection: disseminating AirNow's
  data as received (bluegull-aqi-10h.17) means not second-guessing its
  magnitude past the one well-defined, unambiguous boundary (negative is
  impossible; anything non-negative is AirNow's data to report, however
  extreme -- Oregon DEQ recorded readings "well over 500" during the 2020
  wildfires). Tested with a real historical value (AQI 650, matching that
  fixture) confirming it renders as valid `.beyondAQI` data rather than
  blanking. 22/22 tests pass via `swift test`.
- 2026-07-30 — Implemented bluegull-aqi-q9r.15 (stale-while-revalidate +
  single-flight cache) and q9r.16 (concurrent-behavior tests).
  - On a cache miss: an expired-but-present entry is served immediately
    (`Cache.get_stale()`) while at most one concurrent request wins a
    DynamoDB conditional-write lock (`Cache.try_acquire_refresh_lock()`) to
    actually call AirNow; a true cold start (nothing cached at all) waits,
    bounded, for the winner rather than also calling AirNow. TTL now aligns
    to the next boundary since the epoch (`cache.seconds_until_next_boundary()`)
    -- matching AirNow's roughly-hourly NowCast cadence -- instead of a
    rolling window from each entry's own first-request time.
  - Two real concurrency bugs were found and fixed only by testing this live
    against genuinely concurrent requests, not by unit tests with a
    simulated lock: (1) `Cache.put()` used PutItem, which replaces the
    *entire* item and was silently clearing the lock attribute the instant
    the winner wrote its result -- opening a window for a slower request to
    acquire a "fresh" lock and redundantly re-fetch from AirNow right after
    a successful refresh. Fixed by switching to UpdateItem, touching only
    Data/FetchedAt/ExpiresAt. (2) A second race in the gap between a
    request's own initial miss-check and its own lock-acquisition moments
    later: another request could complete an entire fetch-and-cache cycle in
    that window, and without re-checking, the winner would redundantly
    re-fetch data that already existed. Fixed by re-checking the cache
    immediately after winning the lock, before actually calling AirNow.
  - This is a good example of why "run the local server and try it" matters
    beyond typechecking/unit tests (per this repo's own stated review
    standard): both bugs passed a 55-test suite cleanly, including tests
    specifically targeting this feature, and were only caught by firing real
    concurrent HTTP requests at `make run-local`. That in turn required
    fixing `bin/run_local.py` itself, which used the single-connection-at-a-
    time `HTTPServer` -- serializing "concurrent" requests and making the
    race impossible to observe locally at all -- switched to
    `ThreadingHTTPServer`.
  - Verified live at increasing scale (10, then 20 genuinely concurrent
    requests via `ThreadingHTTPServer` against real AirNow) after each fix:
    exactly one AirNow call per batch, all responses correct, TTL confirmed
    aligned to the exact top of the UTC hour. Added `test_concurrent_cache.py`
    (real `threading.Thread`-based races, not a simulated lock -- deliberately
    the kind of test that actually would have caught both bugs) as the
    permanent regression coverage for q9r.16. 57/57 tests pass, pylint
    10.00/10, `sam validate --lint` clean. Also added the missing
    `dynamodb:UpdateItem` IAM permission to the Lambda execution role in
    `template.yaml` (needed by the new lock/put mechanics; local testing
    against DynamoDB Local doesn't enforce IAM, so this would only have
    surfaced as a real deploy-time failure otherwise).
- 2026-07-30 — Implemented bluegull-aqi-10h.17: added `ComplianceTests.swift`,
  a regression guard that scans every `.swift` file under `Sources/` (comments
  stripped, so the prose that names these very terms to explain the
  constraint doesn't trip it) for identifiers that would only appear in a
  client-side AQI derivation (`breakpoint`, `interpolat`, `computeAQI`,
  `deriveAQI`, `calculateAQI`, etc.) -- the hard constraint that AirNow's AQI
  values must be displayed exactly as received, never recomputed from a
  concentration. Verified the guard actually catches a violation (not just
  that it currently passes) by temporarily injecting a `computeAQI` function,
  confirming the test failed, then restoring the file. The rest of this
  constraint was already satisfied by construction from bluegull-aqi-10h.2:
  `AQICategory.init(aqi:)` only ever consumes AirNow's own `nowcastAQI`, and
  `PollutantReading` has no concentration/breakpoint field to derive from.
  16/16 tests pass via `swift test`.
- 2026-07-30 — Moved the local-dev AirNow key's 1Password item from the
  Personal vault to a dedicated **BlueGull** vault (Steve's own 1Password-side
  move). Updated the `op://Personal/...` reference to `op://BlueGull/...` in
  `service/.env` (real, gitignored) and `service/.env.example`, and the
  secrets inventory in this doc. Also fixed a stale `AWS_REGION=us-east-1` in
  `service/.env`, left over from before the region switch to us-east-2 —
  same bug as the one already fixed in `.env.example` on 2026-07-29, just not
  in the real file since it isn't committed.
- 2026-07-30 — Implemented bluegull-aqi-10h.2: shared BluegullAQIKit models
  (`Location`, `PollutantReading`, `AQIReading`, `AQICategory`/`AQIColor`).
  `PollutantReading` property names match AirNow's JSON keys exactly
  (including `siteID`'s capitalization) so Codable synthesis needs no manual
  CodingKeys and there's no chance of a silent field-mapping mismatch;
  `nowcastAQI` is optional to allow for a response that supplies a raw
  concentration without a computed AQI (bluegull-aqi-10h.17), though the
  `ziplatlong` endpoint this project actually uses hasn't been observed to
  omit it. `AQICategory` is the single shared TAD Table 1/2 mapping (colors
  specified as a plain `AQIColor` byte-triple, not `Color`/`NSColor`, so the
  package stays UI-framework-free -- callers must apply the sRGB color space
  explicitly at the point of use, per the Display-P3 gotcha) and handles
  `> 500` as `.beyondAQI`, same color/recommendations as Hazardous
  (bluegull-aqi-10h.16). Deliberately did NOT add a "dominant pollutant"
  convenience (which pollutant's AQI to headline when several are returned)
  -- that's a UI-facing decision for whichever task actually renders the
  number (e.g. `bluegull-aqi-e70.11`'s popover), not something to bake into
  the shared data model. 15 tests (`swift test`), including boundary tests
  for every TAD threshold and exact color/hex verification against the
  table, decoding from a JSON fixture matching AirNow's real response shape.
- 2026-07-30 — Decided bluegull-aqi-8ef.2: default data-source mode for a fresh
  install is **Service mode** (works immediately, no AirNow key needed), with
  Direct mode available as a settings toggle (`bluegull-aqi-e70.3`, still to be
  built). Steve's call, asked directly since it's a product decision, not an
  engineering default.
- 2026-07-30 — Implemented bluegull-aqi-q9r.20 (AirNow stub/test mode for load
  testing, a prerequisite for q9r.21's load test suite -- driving concurrent
  uncached requests at the live AirNow API would burn quota and plausibly
  violate its terms). New `airnow_stub.py` gates canned data on BOTH an
  `AIRNOW_STUB_MODE=1` env var AND a reserved, obviously-synthetic coordinate
  (40.0, -100.0) -- either alone is not enough, so a stage with the env var set
  can't accidentally serve stub data for a real request, and the reserved
  coordinate behaves like any other real location when the env var is unset.
  Deliberately NOT a template.yaml environment variable, so it can't be baked
  into a deployed stack by a stray parameter-override -- enabling it for an
  actual load test run is out-of-band and out of this task's scope. Wired into
  `aqi_lookup.get_aqi()` so stub responses still flow through the real cache
  read/write path -- only the outbound AirNow HTTP call itself is replaced,
  and key resolution is skipped entirely for stub requests. Verified live via
  `make run-local` with `AIRNOW_STUB_MODE=1`: first request is a genuine cache
  miss served from the stub (log line explicitly distinguishes this from a
  real AirNow fetch), second is a cache hit; same coordinate without the env
  var set correctly falls through to a real AirNow call. 42/42 tests pass,
  pylint 10.00/10.
- 2026-07-30 — Implemented bluegull-aqi-q9r.31 (cost circuit breakers) and closed
  q9r.17 as a side effect (its remaining scope -- ARM64 architecture, DynamoDB
  on-demand billing -- was already satisfied; it explicitly deferred reserved
  concurrency to q9r.31). Added `LambdaReservedConcurrentExecutions` (default 20,
  deliberately conservative since this AWS account is shared with Plant-Tracer)
  and `ApiThrottlingRateLimit`/`ApiThrottlingBurstLimit` (defaults 10/20 req/s) as
  SAM Parameters, wired to `AqiFunction.ReservedConcurrentExecutions` and
  `AqiHttpApi.DefaultRouteSettings`. These are the PRIMARY defense against
  denial-of-wallet: Lambda, API Gateway, and on-demand DynamoDB all bill
  elastically, and WAF (q9r.5, not deployed yet) bills per request itself so it
  amplifies cost under attack rather than capping it. Template-only change --
  `sam validate --lint` and `sam build` both succeed, no Python code touched, no
  actual AWS deploy performed. The specific concurrency/throttling numbers are a
  reasonable, easily-adjustable-via-parameter starting point rather than a
  measured traffic estimate -- flagged to Steve for possible tuning.
- 2026-07-30 — Implemented bluegull-aqi-q9r.30: reject invalid/out-of-coverage
  coordinates before any cache lookup or AirNow call. New `coverage.py` validates
  physical range (-90..90 lat, -180..180 lon) and a deliberately generous North
  America bounding box (lat 14-72, lon -170 to -52 -- covers CONUS, Alaska,
  Hawaii, Puerto Rico, Canada, Mexico; not a precise polygon, since a location
  inside the box without a nearby monitor still just gets AirNow's normal empty
  response). `aqi_lookup.get_aqi()` calls this before even instantiating the
  cache client, closing the gap the issue called out: stale-while-revalidate +
  single-flight (q9r.15, not yet built) only collapses concurrent requests for
  the *same* key, so an attacker cycling through distinct out-of-coverage
  coordinates could otherwise still burn the AirNow quota and fill DynamoDB with
  junk on every request. The cache-key grid-snapping half of this issue was
  already done (cache.location_key()'s 2-decimal rounding, from q9r.2). Error
  messages never echo the submitted coordinates (consistent with q9r.27).
  Fixed two pre-existing tests that used non-North-American coordinates (London;
  a point south of the coverage box) written before this validation existed.
  Verified live via `make run-local`: a valid Chicago request succeeded: a
  Pacific Ocean point, Paris, and an out-of-range latitude all returned 400
  without any AirNow request or cache-log line appearing. 35/35 tests pass,
  pylint 10.00/10.
- 2026-07-30 — Implemented bluegull-aqi-8ef.7 (secret-scanning pre-commit hook +
  CI). Switched tool choice from gitleaks (feature-complete, maintenance-only) to
  **Betterleaks**, its actively-developed drop-in-compatible successor, after the
  user flagged gitleaks' own README warning about the switch -- verified via web
  search rather than assumed. Added `.betterleaks.toml` (`[extend] useDefault =
  true` plus two custom rules for the AirNow key's context: assignment to
  `AIRNOW_API_KEY`/`API_KEY`, and a token following `API_KEY=` in a URL containing
  `airnowapi.org`), verified against real/placeholder values with `betterleaks
  stdin` and against this repo's full git history with zero false positives or
  pre-existing leaks. Wired the local hook into `.beads/hooks/pre-commit` (not a
  separate `.pre-commit-config.yaml`/Python `pre-commit` framework install, which
  conflicts with Beads already owning `core.hooksPath` -- discovered by actually
  trying `pre-commit install` and reading its refusal). Added
  `.github/workflows/secret-scan.yml` as the CI backstop, pinned to v1.7.2 with
  checksum verification, dry-run tested locally before trusting it in CI. Verified
  live end-to-end: a staged fake `AIRNOW_API_KEY=` value was blocked by the hook; a
  clean commit still succeeded, including Beads' own hook logic firing afterward.
- 2026-07-30 — Closed bluegull-aqi-q9r.13 (local run instructions were already
  covered by `service/README.md`) and implemented bluegull-aqi-q9r.27: the
  AirNow key and raw/rounded coordinates must never reach log output.
  `airnow_client.py` now logs only the static, keyless base URL and HTTP
  status codes -- the query string carrying `API_KEY` is never passed to a
  logger. `cache.py` gained `hash_location_key()`, a one-way digest logged in
  place of the location key everywhere (`cache.py`, `aqi_lookup.py`,
  `lambda_handler.py`'s AirNowError path) -- deliberately coarser than "just"
  rounding, since even the 2-decimal cache key would otherwise accumulate an
  "IP was near location Y at time Z" history over the log retention period.
  Also found and fixed a related gap while testing: `lambda_handler.py`'s
  `logging.basicConfig(level=LOG_LEVEL)` was setting the *root* logger, so
  `LOG_LEVEL=DEBUG` (the `.env.example` local-dev default) also unmuted
  botocore's own DEBUG logging, which dumps raw DynamoDB item bodies --
  i.e. the unhashed LocationKey -- straight to the console. Root now stays
  pinned at WARNING; only the `bluegull_aqi_service` logger tree honors
  `LOG_LEVEL`. Verified live via `make run-local` with `LOG_LEVEL=DEBUG`
  (the worst case) against both a cache-hit and a cache-miss/AirNow-fetch
  request: log output showed only the hash, never the key or raw
  coordinates. New `test_logging_redaction.py` (7 tests) asserts this with
  `caplog`, scoped to the `bluegull_aqi_service` logger so botocore's own
  verbose debug output doesn't produce false failures. 21/21 tests pass,
  pylint 10.00/10, `sam validate --lint` clean.
- 2026-07-29 — Moved the local-dev AirNow key from a plaintext `.env`/`.envrc`
  literal to a 1Password reference: Personal vault, item "BlueGull AQI - AirNow
  API Key" (API Credential type, `credential` field), invoked via
  `op run --env-file=.env -- <command>` so the real value only ever exists in a
  single process's environment, never on disk or in a persistent shell. Verified
  the `op run --env-file` syntax against 1Password's own docs before recommending
  it. Updated `.env.example`, `service/README.md`, and the secrets inventory
  accordingly; also fixed a stale `AWS_REGION=us-east-1` in `.env.example` left
  over from before the region switch to us-east-2. The actual `.env`/`.envrc`
  edits were left to Steve to do himself, since making them would have required
  reading his real key.
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
- 2026-07-28 — Switched the deploy region from us-east-1 (the Plant-Tracer-matching
  default) to **us-east-2**, for cost. Added a Decisions table row for region (there
  wasn't one before), updated `service/samconfig.toml`, and recorded a real technical
  finding while checking for conflicts: `AWS::Serverless::HttpApi` custom domains are
  regional-only, so the ACM cert for `aqi.bluegull.org` just follows the API into
  us-east-2 with no special handling. The one exception is CloudFront
  (`bluegull-aqi-q9r.33`, deferred) — its cert must be in us-east-1 always,
  regardless of the origin's region — noted on that task so it isn't a surprise if
  it's ever picked up.
- 2026-07-28 — Local AWS CLI access set up for `843088391598`: standalone account
  (not part of Plant-Tracer's AWS Organization), so IAM Identity Center was enabled
  fresh in it, using root only for that one bootstrapping step — the documented
  legitimate root use case, since no other identity exists yet in a new account.
  Verified profile `AdministratorAccess-843088391598` resolves to an assumed role
  through `AWSReservedSSO_AdministratorAccess`, not root, in the correct account.
- 2026-07-28 — AirNow API key for the service obtained. Per the credential-handling
  rule, the key was never pasted into chat — added `service/.env.example`
  (`AIRNOW_API_KEY` + local-dev vars, no real value) and gave exact commands to run
  directly for the two places the real key goes: a local `.env` (gitignored) and AWS
  SSM Parameter Store. Decided the SSM parameter name: `/bluegull-aqi/airnow-api-key`
  (SecureString), one key shared across all three stacks rather than per-environment.
  Closes `bluegull-aqi-8ef.1` and `q9r.28`, unblocking `q9r.2` (handler) and `q9r.4`
  (SSM wiring) — 26 issues ready, `q9r.2` chief among them.
- 2026-07-28 — **Scaffolding started.** `service/` (SAM: `template.yaml` with a bare
  HTTP API + placeholder Lambda, `pyproject.toml`, `Makefile`, tests — all verified:
  `poetry install`, `pytest`, `pylint` 10/10, `sam validate`, `sam build`) and
  `mac-app/BluegullAQIKit/` (SPM package, macOS 14 minimum, builds and tests clean).
  Closes `bluegull-aqi-q9r.1` and `bluegull-aqi-10h.1`. Targets **Python 3.14**, not
  3.12 — Plant-Tracer's 3.12 pin turned out to be for VM-distribution compatibility
  (a constraint we don't have, being Lambda-only from day one), and their own
  [tracked follow-up](https://github.com/Plant-Tracer/webapp/issues/1114) confirms
  Lambda now supports 3.14. Also discovered empirically that SAM's `RequirementsFile`
  resolves relative to `CodeUri` (`src/`), not the template root — Plant-Tracer's own
  `.gitignore` confirms they don't commit it either, generating it fresh at build
  time from `poetry.lock`. 26 issues now ready, up from 16.
- 2026-07-28 — **Delegation confirmed live**: `dig NS aqi.bluegull.org` returns the 4
  expected `awsdns` nameservers. Squarespace's NS-record UI worked once pointed at
  the right screen — no DNSSEC or trailing-dot issue in the end. ACM DNS validation
  for `aqi.bluegull.org` (and the dev/stage subdomains once their records exist) can
  now proceed.
- 2026-07-29 — **`bluegull-aqi-q9r.2` implemented and verified end-to-end**, along
  with the tightly-coupled `q9r.3` (DynamoDB cache table), `q9r.4` (SSM key
  wiring), `q9r.11` (DynamoDB Local), and `q9r.12` (native local runner) —
  `GET /aqi?lat=&lon=` now really works: cache check, AirNow fallback, cache
  write, all confirmed live against the real AirNow API through
  `bin/run_local.py` (cache miss with real San Francisco readings including
  `reportingAgency`, then a cache hit with zero additional AirNow calls). 14
  tests pass (cache tests against real DynamoDB Local, not moto), pylint
  10/10, `sam build` confirmed to actually bundle dependencies. Deliberately
  not in scope: stale-while-revalidate (`q9r.15`), coordinate/coverage-area
  validation (`q9r.30`), log redaction hardening (`q9r.27`) — each stays a
  separate layer on top of this, not folded in.
- 2026-07-29 — **Closed a real gitignore gap, caught before any leak occurred.**
  While staging the `q9r.2` implementation, found a `.envrc` (direnv) file at the
  repo root holding the real AirNow API key as a plain `export` — and `.gitignore`
  didn't cover it: `.env.*` doesn't match a filename with no dot before `rc`.
  Verified via `git log --all` that it had never been committed, then added
  `.envrc` explicitly to `.gitignore` and recorded the pattern in the secrets
  inventory. The key's value was never written anywhere (chat, commit, or issue) —
  only its filename/location was ever referenced.
- 2026-07-28 — Recorded where `bluegull.org` is actually registered: **Squarespace**.
  Fills in the "wherever `bluegull.org`'s DNS otherwise lives" placeholder used
  throughout the domain-delegation writeups with a concrete answer — the NS
  delegation record for `aqi.bluegull.org` gets added in Squarespace's domain DNS
  settings; the rest of `bluegull.org`'s DNS there is untouched.
- 2026-07-28 — Decided three named backend stacks: **prod** `aqi.bluegull.org`,
  **dev** `dev.aqi.bluegull.org`, **staging** `stage.aqi.bluegull.org`. First-pass
  hyphenated names (`dev-aqi.bluegull.org`) were reconsidered once it came up that
  they're DNS *siblings* of `aqi.bluegull.org` rather than subdomains, so couldn't
  share its hosted zone — dot-subdomains keep the single-delegation approach for all
  three. Updated `bluegull-aqi-q9r.6` and `q9r.8` with the concrete hostnames.
- 2026-07-28 — AWS account decided: **`843088391598`**, dedicated to this project
  (closes `bluegull-aqi-8ef.4`). `bluegull.org`'s existing DNS lives elsewhere and
  stays there; `aqi.bluegull.org` will be delegated via NS record to a dedicated
  Route53 hosted zone in that account rather than migrating the apex domain. Raised
  a new open question: whether stage deployments get subdomain prefixes
  (`dev.aqi.bluegull.org`, matching Plant-Tracer's pattern) or `aqi.bluegull.org` is
  the one deployed stage — either fits the hosted zone already being created.
- 2026-07-28 — Domain decided: **`aqi.bluegull.org`**. Closes
  `bluegull-aqi-8ef.3`, unblocking `bluegull-aqi-q9r.6` (Route53/ACM config in
  `template.yaml`). Whether the `bluegull.org` hosted zone already exists in the
  target AWS account is unverified and left for that task to confirm.
- 2026-07-28 — **🔓 Gate lifted.** The AirNow terms review (`bluegull-aqi-8ef.10`, P0)
  is reviewed, approved, and closed: caching and redistributing AirNow data via a
  proxy server is permitted, so Service mode proceeds alongside Direct mode and **all
  implementation is unblocked**. Compliance obligations are unaffected and still gate
  App Store submission. Also scrubbed a personal detail about the project owner that
  had no business in a public repo.
- 2026-07-28 — Decided: health guidance (TAD Tables 3–4 sensitive groups and
  cautionary statements) is **deferred past v1** — `bluegull-aqi-mtm.16`, kept open
  at P4 and linked to the post-v1 richer detail view. Defensible specifically because
  it isn't an obligation on us. Also added a **"Deferred past v1"** table to the
  build-order section, collecting all six deferred items in one place with the reason
  each is safe to defer, and naming what is deliberately *not* deferrable (attribution,
  the preliminary-data disclaimer, official AQI colors, never-derive-AQI) — the line
  throughout being what the AirNow guidelines require of us versus what is good
  product.
- 2026-07-28 — **Corrected a factual error from the same day's review**: I reported a
  divergence between airnow.gov ("301 +") and the TAD (301–500 + "Beyond the AQI").
  There is none — the "301 +" came from a collapsed text extraction; the site's
  expanded legend panel matches the TAD exactly. Steve's screenshot caught it. Also
  resolved the resulting open question in the right direction: an AQI above 500 is
  **valid off-scale data, not bad data** — EPA documents how to compute it (including
  under NowCast), and Oregon DEQ published readings above 500 during the September
  2020 wildfires. The design point that survives is the inverse of the original
  worry: the model must not treat >500 as invalid, since that would blank the app
  during precisely the conditions producing such readings. `bluegull-aqi-10h.16`
  updated accordingly, with malformed values (negative, non-numeric, absurd) kept as
  a distinct error path.
- 2026-07-28 — Reviewed the AQI Technical Assistance Document (EPA 454/B-18-007) and
  the AirNow API Fact Sheet, which Steve supplied. Biggest concrete win: the
  **authoritative AQI category table and exact RGB values** (Table 1/Table 2) are now
  recorded verbatim and loaded into `bluegull-aqi-10h.2`, replacing every prior
  hand-wave about "official EPA colors" — including two values a naive implementation
  gets wrong (Green is `0,228,0`, Maroon is `126,0,35`). Also refines Steve's framing
  of the TAD's applicability: the reporting obligations don't bind us, but the Data
  Exchange Guidelines *incorporate* TAD Tables 1–2 by reference, so those do. Six new
  tasks (`10h.16`–`10h.20`, `mtm.16`), and a `compliance` label backfilled across all
  13 AirNow-obligation issues so the set is visible as a whole
  (`bd list --label compliance`). Two new open questions: how to display AQI > 500
  ("Beyond the AQI"), and whether health/cautionary content belongs in v1.
- 2026-07-28 — Closed the "does the widget need attribution/disclaimer too" question
  left open earlier: yes, via a **tap-to-expand** detail view (`bluegull-aqi-mtm.14`)
  reached through WidgetKit's `widgetURL`, the same pattern Apple's Weather widget
  uses — a user may have the widget on their desktop without ever opening the menu
  bar popover, so the widget needs its own path to the same compliance content.
  Both `bluegull-aqi-e70.10` and `dc2.4` now target both surfaces. Also filed
  `bluegull-aqi-mtm.15`, explicitly deferred past v1: that same detail view is a
  natural place to eventually show richer data than the widget face does, more like
  Apple Weather's expanded view — good scope creep, correctly not built yet.
- 2026-07-28 — Refined the EPA-apps-as-evidence principle with the precise legal
  point: EPA is not bound by the Data Exchange Guidelines it imposes on third-party
  *recipients* of its data, so its own app isn't a party demonstrating compliance
  with a rule that binds it — its choices are informative about what EPA would
  likely find acceptable from someone else, not proof of a compliant floor. Also
  designed the concrete UI home for attribution and the disclaimer: the menu bar
  status item has no room for either, so both live in a `.window`-style **popover**
  (`bluegull-aqi-e70.11`, new) reachable by clicking the status item — guaranteed
  available regardless of whether the user ever places the desktop widget, unlike
  relying on the widget alone. Retargeted `bluegull-aqi-e70.10` and `dc2.4` at it.
- 2026-07-28 — **Corrected an overclaim**: the previous entry's "resolved, not just
  theorized" language treated a live check of airnow.gov as settling the attribution
  question. Steve corrected this — app implementations may *suggest* compliant
  practice, but the written Data Exchange Guidelines are what actually control, and
  his reading of that text is the real gate, not my inference from what one EPA
  product happens to do. Added an explicit "On using EPA's own apps as evidence"
  caveat and reworded the attribution and disclaimer findings (and their Beads tasks,
  `bluegull-aqi-10h.15`/`e70.10`/`dc2.4`) to frame app precedent as corroborating,
  not dispositive. Also recorded a new fact without over-concluding from it: the
  iOS app's preliminary-data disclaimer lives in an About page via dropdown menu,
  distinct from attribution's persistent-footer treatment; no equivalent found yet on
  airnow.gov itself.
- 2026-07-28 — Steve pointed out that EPA's own AirNow iOS app implements
  attribution, prompting a live check against airnow.gov rather than continuing to
  theorize. Confirmed the exact pattern: a persistent small "Data courtesy of
  {agency}" footer (e.g. "Bay Area Air District") plus a separate "EPA and PARTNERS"
  logo, always visible next to the reading — not a Settings/About screen, and not a
  generic class credit. Corrects both `bluegull-aqi-10h.15` and `bluegull-aqi-e70.10`,
  which had been scoped on an untested assumption about placement and specificity.
  Also confirmed the exact AQI category name string including the "(USG)"
  abbreviation, added to `bluegull-aqi-10h.2`.
- 2026-07-27 — Turned the other four terms-review findings into actual Beads tasks,
  matching the AQI-colors fix: two-tier attribution (`bluegull-aqi-10h.15` derives the
  text, `bluegull-aqi-e70.10` surfaces it), the in-product preliminary-data disclaimer
  (`bluegull-aqi-dc2.4`), notifying AirNow the product exists (`bluegull-aqi-8ef.13`),
  and keeping contact info current (`bluegull-aqi-8ef.14`, filed as a standing
  reminder rather than a one-time task). The attribution and disclaimer tasks now
  gate App Store submission, same as the terms review itself.
- 2026-07-27 — Caught that the AQI-colors obligation from the terms review had been
  documented as a finding but never actually turned into a design decision or task —
  the widget/menu bar tasks still said nothing about it. Added it to the Decisions
  table and to `bluegull-aqi-10h.2` (shared models) plus all four UI display tasks
  (`mtm.4/5/6`, `e70.6`), so it's a single shared mapping in `BluegullAQIKit` rather
  than something each UI target could reinvent inconsistently.
- 2026-07-27 — Completed primary-source research for the AirNow terms review
  (fetched the actual EPA Data Exchange Guidelines PDF and the account registration
  page). Reassuring on the big question — nothing prohibits Service-mode
  redistribution, and AirNow's own FAQ endorses the caching pattern already designed
  — but surfaced five concrete obligations the design doesn't yet satisfy
  (two-tier attribution, an in-product preliminary-data disclaimer, official AQI
  colors, notifying AirNow the product exists, keeping contact info current) and one
  soft interpretive tension (hourly cache vs. "most current data available"). This is
  research to support Steve's sign-off, not a conclusion — the P0 gate on all
  implementation stays in place until he closes `bluegull-aqi-8ef.10`.
- 2026-07-27 — Added a Security & abuse resistance section with an explicit threat
  model. Three gaps the earlier design missed: **denial of wallet** (an elastic stack
  bills elastically, and nothing bounded the burn rate), a **cache-cardinality
  attack** that the stampede mitigation does not cover (distinct-key floods, not
  same-key ones), and an inadvertent **location-history database** accumulating in
  request logs. Also recorded what is deliberately out of scope, so it gets re-argued
  rather than silently adopted. Filed 11 new issues, all labelled `security`
  (`bd list --label security`); four are pre-launch blockers gating the dev deploy.
- 2026-07-27 — Promoted the no-secrets-in-git rule from scattered implementation
  notes to a top-level policy section with a full credential inventory, named
  project-specific leak vectors (notably that AirNow passes its key as a URL query
  parameter, so unredacted request logging leaks it into CloudWatch), and three
  enforcement layers. Added secret patterns to `.gitignore`, mirrored the rule into
  `CLAUDE.md`/`AGENTS.md` so agent sessions inherit it, and filed 6 Beads tasks.
- 2026-07-27 — Added absolute performance ceilings alongside the relative regression
  gates (warm cached p95 < 50ms, cold start p50 < 600ms, etc.), since a relative-only
  gate permits unbounded slow drift. Clarified that all gated latency is server-side;
  client-observed latency is tracked but never gated. Ceilings are estimates pending
  the first dev-stage deploy, with a task to tighten them against real numbers.
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
