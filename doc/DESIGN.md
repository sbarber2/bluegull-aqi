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
| AQI category colors | Official EPA AQI RGB palette only, sourced once in `BluegullAQIKit`'s shared models and used by both the menu bar and widget — never a custom palette. Compliance requirement from the AirNow Data Exchange Guidelines, not a style preference; see "AirNow terms review" below. |

## Secrets & credentials

**No credential, API key, token, certificate, or private key is ever committed to
this repository.** This is a hard invariant, not a preference — the repo is public,
and a leaked key in git history is leaked permanently even after a follow-up commit
removes it. Rotation, not deletion, is the only real remedy once it happens.

### Inventory — every secret in this project and where it lives

| Secret | Home | Never |
|---|---|---|
| Service's AirNow API key | SSM Parameter Store (SecureString) or Secrets Manager, read by the Lambda execution role | In source, in `template.yaml`, or as a CloudFormation parameter default |
| User's own AirNow API key (direct mode) | iCloud Keychain on the user's Mac | Bundled in the app binary or in any repo file |
| Local dev AirNow key | `.env`, gitignored; `.env.example` committed with placeholders only | Committed, even "temporarily" |
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
2. **gitleaks as a pre-commit hook** — catches it locally before a commit exists,
   which is the cheapest possible point to catch it.
3. **gitleaks in CI** — backstop for commits made without the hook installed (fresh
   clones, other machines, other agents).

⚠️ **Pattern scanners will not catch the AirNow key on their own.** Push protection
and gitleaks' default rules key on distinctive credential formats — AWS `AKIA…`,
GitHub `ghp_…`, Stripe `sk_live_…`. The AirNow key carries no such prefix; like most
government API keys it's a generic token, indistinguishable from any other opaque
string. So layer 1 protects the AWS and Apple credentials in the inventory above but
**not this project's primary secret**.

Closing that hole requires a **custom gitleaks rule keyed on context rather than
token shape**: assignments to `AIRNOW_API_KEY`/`API_KEY`, and high-entropy tokens
appearing near `airnowapi.org`. Without it, the enforcement stack has a gap exactly
where it matters most — which is precisely why layers 2 and 3 are not redundant with
layer 1.

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
nothing in the base design bounds. WAF's per-IP rate limiting does little against a
botnet or a handful of cheap cloud instances, and WAF bills per request itself, so
under attack it amplifies cost rather than capping it.

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
- **WAF managed rule sets** beyond rate limiting — one read-only endpoint taking two
  numeric parameters has almost no injection surface.
- **Multi-region, penetration testing** — not until scale justifies them.

**Strong later candidate: CloudFront in front of the API.** The response is identical
for everyone in a region and changes hourly, which is nearly an ideal CDN workload. It
would absorb most traffic at the edge before reaching Lambda, cutting cost and attack
surface together. Not worth the complexity pre-launch; the natural first move if scale
materializes.

### Unverified — confirm before relying on

- Current minimum threshold and evaluation window for WAF rate-based rules.
- Whether Apple's **App Attest** supports native macOS (well-established on iOS). If
  it does, it's the real answer to "only our app may call this" — but nothing should
  be designed around it until confirmed.

## AirNow terms review — research findings (pending sign-off)

Primary-source research for `bluegull-aqi-8ef.10`, done 2026-07-27. This is fact-
gathering and a first read, not a legal conclusion — the actual sign-off is Steve's
call (he formerly practiced copyright law), and this section is written to support
that judgment, not substitute for it. **The P0 gate stays in place until he closes
this issue.**

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
the written guidelines**. The Data Exchange Guidelines text is what controls; an app
implementation can suggest a reasonable, EPA-sanctioned way to satisfy a requirement,
but it cannot independently establish that a given placement or wording *is*
compliant — EPA's own products could be exceeding what's required, or could
themselves be non-compliant with their own guidelines, and neither possibility is
something an app screenshot can rule out. Steve's read of the actual text governs;
app precedent below is offered as suggestive input to that judgment, not as a
finding in itself.

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
   the response field or lookup that supplies it) and `bluegull-aqi-e70.10` (surface
   it as a persistent footer in the primary UI, corrected from the original
   About-screen placement); both gate App Store submission. Whether the widget
   itself also needs this (vs. relying on the menu bar to carry it) is left as an
   open call in `bluegull-aqi-e70.10` — small-widget space is genuinely tight.
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
   Tracked as `bluegull-aqi-dc2.4`; gates App Store submission.
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
- **No explicit commercial-use clause, no App Store-specific restriction.** Absence of
  a restriction isn't the same as an affirmative permission, and the registration flow
  might surface additional text once an account actually exists (a step I haven't
  taken).

### Questions for Steve's sign-off

- Does "nothing prohibits it" + the FAQ's explicit caching endorsement read to you as
  sufficient permission for Service mode, or does the absence of an explicit
  redistribution *grant* (as opposed to absence of a prohibition) change your read?
- Is the "make known to... the EPA AirNow program" obligation satisfied by informal
  registration, or does it warrant actually completing and returning the Data
  Exchange Guidelines acknowledgment form as a discrete step?
- Does the two-tier attribution obligation require dynamically crediting the specific
  reporting agency per reading, or is a generic "state, local, and tribal air quality
  agencies, and the EPA AirNow program" credit sufficient?
- Any read on the "most current data available" language that should change the
  1-hour cache TTL, or is hourly clearly fine?

## Open questions (blocking or semi-blocking)

- **⛔ Does AirNow's licensing permit Service mode at all?** — *gates all
  implementation work* (`bluegull-aqi-8ef.10`, P0). Research is done — see "AirNow
  terms review — research findings" above — but the sign-off is Steve's call, not a
  conclusion reached here. Every scaffold task stays blocked until he closes that
  issue.
- **Default data-source mode** for a fresh install (Service vs. Direct) — see above.
  Note this is moot if the licensing review rules out Service mode.
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

All latency figures are **server-side** — measured from API Gateway receiving the
request to sending the response. Client-observed latency additionally includes DNS,
TLS handshake, and physical distance (a California client hitting `us-east-1` pays
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
