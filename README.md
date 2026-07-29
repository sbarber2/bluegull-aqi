# BlueGull AQI

A macOS menu bar app and desktop widget that shows local air quality, using data from
the US EPA's [AirNow](https://www.airnow.gov) program.

> **Status: early scaffolding.** The backend (`service/`) and the shared Swift
> package (`mac-app/BluegullAQIKit/`) exist as bare, tested skeletons — no real
> AQI-fetching logic yet. The menu bar app, widget extension, and most of the
> backend's actual behavior are still just design and task graph. See
> [doc/DESIGN.md](doc/DESIGN.md) for the full design and
> [Task tracking](#task-tracking) for what's queued up.

## What it will do

- **Menu bar** — current overall AQI at a glance, always visible.
- **Desktop widget** — current AQI plus the full pollutant breakdown (PM2.5, PM10,
  ozone, and whatever else the nearest monitor reports), in small, medium, and large
  sizes.
- **Locations** — follows your Mac's current location, and lets you pin specific
  places (home, work, a zip code you care about) and choose which one a given widget
  instance shows.
- **Hourly refresh**, matching the cadence at which AirNow itself publishes new
  observations. Polling faster wouldn't produce fresher data.

Requires **macOS 14 (Sonoma) or later** — desktop widgets need it.

## Two ways to get data

The app can source readings either way, and the choice is a setting:

- **Direct** — you supply your own AirNow API key (free from
  [airnowapi.org](https://docs.airnowapi.org)), and the app talks to AirNow directly.
  No dependency on our backend, and no rate limit shared with anyone else. The key is
  stored in your iCloud Keychain, so it follows you to your other Macs.
- **Service** — the app calls a small hosted proxy (AWS Lambda) that holds its own
  AirNow key and caches aggressively. Works immediately with no signup, at the cost of
  a shared, rate-limited backend.

Both paths return identical data to identical code, so the rest of the app doesn't
know or care which one answered.

## Repository layout

```
bluegull-aqi/
├── doc/
│   └── DESIGN.md          # the design record — start here
├── mac-app/
│   ├── BluegullAQI/        # (planned) menu bar container app
│   ├── BluegullAQIWidget/  # (planned) WidgetKit extension
│   └── BluegullAQIKit/     # shared Swift package: models, clients, cache -- scaffolded
├── service/                # AWS SAM backend — the caching proxy -- scaffolded
│   ├── template.yaml
│   ├── src/
│   └── tests/
├── .beads/                # issue tracker data (see Task tracking below)
├── .github/workflows/     # (planned) CI
├── CLAUDE.md, AGENTS.md   # instructions for AI coding agents
└── LICENSE
```

"Scaffolded" means a real, buildable, tested skeleton with no actual behavior yet —
`service/`'s Lambda handler returns a placeholder response, `BluegullAQIKit` exports
a version constant. `(planned)` means the directory doesn't exist yet.

The `mac-app/` split exists so that the menu bar app and the widget extension share
one core library rather than duplicating logic. It also reflects a platform
constraint: WidgetKit extensions have restricted background networking, so the
container app does the fetching and hands results to the widget through a shared App
Group container.

## Task tracking

This project uses **[Beads](https://github.com/steveyegge/beads)** (`bd`) rather than
GitHub Issues. Issues live in a Dolt database inside the repo and sync over the git
remote, so the task graph travels with the code.

```bash
brew install beads
bd ready          # what's unblocked and available to pick up
bd show <id>      # details for one issue
bd dep tree <id>  # see a phase's breakdown
```

Work is organized as one epic per phase — prerequisites, backend service, shared Swift
package, menu bar app, widget extension, polish, and App Store prep — with
dependencies wired so `bd ready` only surfaces genuinely unblocked work.

## Notes for contributors

Two project constraints are worth knowing before you write anything:

**No credentials in the repository, ever.** This repo is public, and a key committed
to git history stays leaked even after a follow-up commit removes it — rotation is the
only real remedy. Local secrets belong in a gitignored `.env`. One trap specific to
this project: AirNow passes its API key as a *URL query parameter*, so logging a
request URL writes the key into your logs while looking like perfectly ordinary debug
output. Full policy and inventory: [doc/DESIGN.md § Secrets & credentials](doc/DESIGN.md).

**The backend runs and tests locally with no AWS account.** Core logic is kept
separate from the Lambda entry point, and the DynamoDB endpoint comes from an
environment variable, so the same code path runs against DynamoDB Local as against the
real thing. You should never need to deploy to test a change. (The performance
regression suite is the one exception — Lambda cold start can only be measured on real
Lambda — and it runs separately, on a schedule.)

## Data attribution

Air quality data comes from the US EPA AirNow program. AirNow's
[terms of use](https://docs.airnowapi.org) apply to any use of their API, including
attribution requirements.

## License

MIT — see [LICENSE](LICENSE).
