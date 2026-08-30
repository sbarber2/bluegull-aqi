# bluegull-aqi-hib.10 — does an SMAppService agent actually wake on a repeating XPC Activity?

Throwaway spike. It exists to answer one question that
[`hib.1`](../../.beads/issues.jsonl)'s go/no-go rests on and that nobody had
tested: **with no `RunAtLoad` and no `KeepAlive`, does anything ever start the
helper?**

The `hib` epic describes its lifecycle as "modelled on weatherd … entire
lifecycle is public API" and calls it "proven viable". The 2026-08-12 spike
proved something narrower — that a separate bundle can get CoreLocation. It
never touched SMAppService, XPC Activity, or pressured exit.

Nothing here does AQI work and nothing here touches CoreLocation. Fresh bundle
ids under `solutions.bluegull.hib10.*`, deliberately unrelated to any shipping
identifier, so this can be re-run and thrown away.

## The two variants

Both are registered independently, so one reboot answers both — reboots are
the slow part.

| | `solutions.bluegull.hib10.checkin` | `solutions.bluegull.hib10.register` |
|---|---|---|
| Where the schedule lives | the launchd plist (`LaunchEvents` → `com.apple.xpc.activity`) | in code (`xpc_activity_register`) |
| Picked up with | `XPC_ACTIVITY_CHECK_IN` | explicit criteria dictionary |
| `RunAtLoad` | **no** | **yes**, and that is the point |
| What it corresponds to | the design that would actually work | `hib.5` as literally written |

**Variant A needs `RunAtLoad` and that is the finding, not a workaround.**
Criteria that live in code can only be registered by code that runs, and
`hib.3` gives the agent no `RunAtLoad`, no `KeepAlive`, no way for the widget
to start it, and a container app that may never launch again. Something has to
start it once. `RunAtLoad` is the cheapest honest stand-in for "the user
opened the app once."

Reading variant A: `RunAtLoad` explains **one** process start per login. It
does not explain an `ACTIVITY_RUN` five minutes later, and it does not explain
a **second pid**. Those are the signal.

## Questions and how each is answered

| # | Question | Evidence |
|---|---|---|
| 1 | Does `SMAppService.agent` accept a plist with `LaunchEvents`, or silently drop it? | `register()` result, then `launchctl print` — look for an `event triggers` block with the criteria intact |
| 2 | Does it wake with the container app quit? | `ACTIVITY_RUN` lines in the log with no container process alive |
| 3 | Does it survive a reboot with the app never launched? | reboot, wait past one interval, `make logs` |
| 4 | Does it actually exit between wakes? | **the pid on each `ACTIVITY_RUN`** — same pid means it never left, and "on demand" is a costume |

Everything logs at `.notice`, not `.debug`. `.debug` is memory-only and would
be gone by the time anyone reads it after a reboot, which is the measurement
that matters most.

## Running it

```bash
make install
```

Installs to `/Applications`. That location is load-bearing: `SMAppService`
records where the app was at registration time, and a DerivedData path moves
whenever the checkout path does — the exact trap already documented in
`bluegull-aqi-mtm.9` for widget registration.

```bash
HIB10_ACTION=register /Applications/Hib10Container.app/Contents/MacOS/Hib10Container
```

Registers both variants and exits, so "the container app is not running" is
immediately and unambiguously true. `HIB10_ACTION=status` and
`unregister` also work. Opening the app normally gives the same controls as
buttons, plus live status.

Then confirm launchd kept the criteria:

```bash
launchctl print gui/$(id -u)/solutions.bluegull.hib10.checkin
```

Watch, or read back later:

```bash
make logs-live
make logs
```

### The reboot test (question 3) — needs a human

1. `make logs` and note the last timestamp.
2. Reboot. **Do not launch `Hib10Container` afterwards.** Launching it would
   answer a different, much weaker question.
3. Wait past one interval (5 min nominal; give it 20 — the system coalesces
   activities and a nominal interval is a floor, not a promise).
4. `make logs`.

A `PROCESS_START` + `ACTIVITY_RUN` pair after the reboot timestamp, in
`mode=checkin`, with the container never launched, is the answer the epic
needs. Nothing at all is the answer that ends it.

## Cleaning up

```bash
make uninstall
```

Boots out both jobs and removes the bundle. Then check **System Settings →
General → Login Items & Extensions** has no `hib.10 spike` row.

## Deliberately not covered: the location prompt (question 5 on the bead)

The bead lists "launch the helper headless with no location grant and see
whether a prompt appears" as a cheap bonus. It is left out on purpose:

- A locationd grant, once created, **cannot be removed** — `tccutil` has no
  authority over it and fails `-10814` (that is why `hib.2` insists on a fresh
  bundle id). Asking the question consumes a bundle id permanently.
- It only matters if questions 1–4 say yes. If nothing wakes the agent, the
  first-run prompt is moot.
- The answer also depends on whether the shipping helper is a bare tool (as
  here) or an `LSUIElement` app bundle, and questions 1–4 inform that choice.

Worth doing as its own spike, with its own fresh bundle id, once hib.1 has a
direction.

## Notes found while building this

- `RequireNetworkConnectivity`, which weatherd sets and `hib.5` copies, is
  **not a public XPC activity constant** — it does not appear in
  `xpc/activity.h` at all. It can be written into a plist but cannot be set
  from code, and it is not contract.
- `xpc/activity.h`'s own description of `XPC_ACTIVITY_CHECK_IN` — "previously
  registered activity using the same identifier (for example, an activity
  taken from a launchd property list)" — is documented evidence that
  plist-declared activities are a supported mechanism. That is what made
  variant B the primary hypothesis rather than a long shot.
- The public interval constants are `XPC_ACTIVITY_INTERVAL_{1,5,15,30}_MIN`,
  `_1_HOUR`, `_4_HOURS`, `_8_HOURS`, `_1_DAY`, `_7_DAYS`. An hourly refresh is
  a first-class supported cadence.
- xcodegen **generates** the file named by `entitlements: path:` and
  overwrites whatever is there. A hand-written entitlements file with only a
  `path:` gets silently replaced by an empty `<dict/>` on the next `generate`
  — which happened here and produced a signed-but-unsandboxed agent that
  looked fine until the signature was inspected. Entitlements must be spelled
  out under `properties:`, the way `mac-app/project.yml` already does it.
- Xcode's `ProcessProductPackaging` filters entitlements against a
  provisioning profile, and manual Developer ID signing has none — so it
  dropped `app-sandbox` and left only `get-task-allow`. `make build` therefore
  signs by hand, inside-out (nested agent first, then the bundle over it), and
  prints the resulting entitlements so a silently unsandboxed build can't slip
  through again.
