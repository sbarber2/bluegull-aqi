# Verifying the location helper agent

Manual verification for the `bluegull-aqi-hib` epic (`hib.9`).

Almost nothing in this epic is unit-testable. launchd lifecycle, TCC grants,
XPC Activity scheduling and background-item revocation are all OS
integration, and the interesting failures are *silent* — a login item that
still says "enabled" while the agent never runs, a permission recorded as
absent while it is present. Every such failure so far was found by reading
the unified log on a live machine, never by a test. This document exists so
that reading is systematic rather than lucky.

Companion to `doc/DEVINSTALL.md`. Same spirit as the manual checks in
`bluegull-aqi-e70.8` and `mtm.9`.

---

## 0. Feasibility gate — do this first, before anything else

**Does CoreLocation work at all in your test environment?**

A macOS VM has no Wi-Fi radio. CoreLocation's positioning on the Mac leans
on Wi-Fi scanning, so a VM guest may be unable to produce a fix even when
the permission prompt itself works perfectly. That would not break checks A,
B, E, F, G, J or L — which are about prompts, states and copy — but it makes
C, D and I meaningless, because there would be nothing to refresh *with*.

Ten minutes, before investing in the rest:

1. In the VM, open System Settings → Privacy & Security → Location Services.
   Is the master switch present and enabled?
2. Open Maps and press the "current location" arrow. Does it resolve?

Record the answer. If location does not work in the VM, run C/D/I on real
hardware and keep the VM for everything else — which is still the majority
of this list, and still the part that is otherwise unrepeatable.

---

## 1. What you need

- A clean macOS 26.x VM, **snapshotted before first launch**. The snapshot
  is the whole point: see "Why a clean room" below.
- The **pre-helper** build, for the upgrade check:
  `~/BlueGull-verification/BluegullAQI-0.2.1-228-de24af6-PRE-HELPER.dmg`
  (v0.2.1 build 228, commit `de24af6` = `main`, notarized, contains no
  `Contents/Library/LoginItems`). Preserved deliberately — `make app-package`
  does `rm -rf mac-app/build` on every run and would otherwise destroy it.
- The **helper** build: `make app-package` on `feat/location-helper-agent`.
- Both must be notarized Developer ID. An Apple Development build is a
  different signing identity and will not tell you what a user sees.

### Why a clean room

The location grant is **one shot and unremovable**. CoreLocation refuses to
re-prompt once answered, and the record cannot be cleared — `tccutil` has no
authority over locationd and fails `-10814`. On real hardware every clean
first-run test therefore consumes a bundle identifier permanently, which is
why the spike had to burn `solutions.bluegull.hib10.locprobe1`.

Reverting a VM snapshot is the only way to make first-run testing
repeatable. Revert between every check that involves a prompt.

---

## 2. Reading the instrumentation

```bash
/usr/bin/log stream --predicate 'subsystem == "solutions.bluegull.aqi"'
```

```bash
/usr/bin/log show --last 30m --predicate 'subsystem == "solutions.bluegull.aqi"'
```

**Two traps that have each cost real time:**

- **`log` is a zsh builtin.** On a shell where it is shadowed, `log show …`
  fails with "too many arguments". Use `/usr/bin/log` explicitly.
- **`--last` can return nothing after a reboot** while `--start` with an
  absolute timestamp returns everything. Found during `hib.10`, where it
  nearly produced a false negative on the single most important measurement.
  If `--last` looks empty right after booting, retry with
  `--start '2026-09-02 08:00:00'` before concluding anything.

Logging is at `.notice`, **not** `.debug`, and deliberately so. `hib.9`
originally specified `.debug`; that is wrong for this process. `.debug` is
memory-only and gone by the time you read it after a reboot — which is
exactly check D, the one measurement that most needs to survive one.

Useful non-log probes:

```bash
launchctl print gui/$(id -u)/solutions.bluegull.aqi.locationhelper
```

Read `state`, `runs`, `last exit code`, and `properties`. `needs LWCR
update` in `properties` means the Background Task Management record pins a
code requirement the current executable no longer satisfies — see check K.

---

## 3. The checks

Revert the VM snapshot before any check marked **[fresh]**.

### A. Clean install, first run — exactly one prompt [fresh]

Install the helper DMG, launch, and count permission prompts from launch
through first data.

- **Expect:** the Background Updates window opens by itself. Clicking
  **Turn On** produces exactly ONE system location prompt, attributed to
  **BlueGull AQI**. Approving it yields a green "You're all set" and a
  reading.
- **Fails if:** two prompts appear (the app must never ask — that is what
  removing its location entitlement enforces), or the prompt names anything
  other than BlueGull AQI, or it appears before you clicked Turn On.
- **Log:** `HELPER_REGISTERED` → `PROCESS_START … appGroup=ok` →
  `AUTH_REQUESTING` → `AUTH_SETTLED status=authorized asking=true` →
  `REFRESH reason=first-run outcome=refreshed`.
- `AUTH_SETTLED` should follow your click by well under a second. Near
  exactly 120s means the delegate callback never arrived and only the
  deadline's fallback noticed — the regression fixed in `7a8d048`.

### B. "Not now" costs nothing and is re-askable [fresh]

Same as A, but click **Not now**.

- **Expect:** no system prompt at all. The popover offers "Turn On
  Background Updates" indefinitely. Clicking it later still works, and only
  then produces the one prompt.
- **Fails if:** a system prompt appeared anyway, or the offer disappears.

### C. The helper refreshes with the app quit

Complete A, then **Quit BlueGull AQI**. Leave it for an hour.

- **Expect:** `PROCESS_START` / `REFRESH` lines with the app not running.
  `ppid=1` — launchd started it, nothing else could have.
- Wake cadence is `Interval 1800` + `Delay 300` + `GracePeriod 900`, so the
  first wake may legitimately be ~20 minutes and later ones up to ~45
  minutes apart. Measured 2026-09-02: registered 08:37, first wake 08:57.
- `outcome=skipped-still-fresh` is a **pass**, not a miss — the slot was
  still inside its 3600s soft TTL, and skipping is what keeps a 30-minute
  interval from costing extra requests.

### D. Reboot, and the agent is NOT login-scoped

Complete A, quit the app, reboot, and **do not launch the app**.

- **Expect:** the helper eventually wakes on its own. The plist carries no
  `RunAtLoad` and no `KeepAlive`, so anything that runs it is launchd acting
  on the activity.
- **Fails if:** it only ever runs right at login (that would mean the
  activity is not surviving), or never runs at all.
- Remember the `--last` trap above when reading the log after a reboot.

### E. Background item switched off — detected, explained, recoverable

Complete A, then System Settings → General → Login Items & Extensions →
switch **BlueGull AQI** off.

- **Expect:** within one refresh cycle the popover says background updates
  were turned off, offers a working "Turn On", and states that locations
  added by name still work. The widget agrees. Neither surface shows a
  fresher number than the other.
- **Fails if:** the app carries on as if nothing happened (there is no
  notification for this; detection is by polling `SMAppService.status`), or
  the two surfaces disagree.

### F. Refusing the prompt is handled honestly [fresh]

Fresh install, **Turn On**, then **Don't Allow**.

- **Expect:** the app says location is off for BlueGull AQI, that macOS only
  asks once, and points at System Settings → Privacy & Security → Location
  Services, with a button that opens it. It must NOT offer to ask again —
  CoreLocation would silently ignore that.
- **Note:** this burns the grant for that bundle id. Revert the snapshot
  afterwards; there is no other reset.

### G. Pinned locations never break

Throughout every check above, and especially with location refused (F) or
background updates off (E): add a location by zip code in Settings.

- **Expect:** it resolves to a coordinate and fetches. Pinned locations need
  no location grant at all — `CLGeocoder` needs network access, not
  authorization (confirmed 2026-09-02, `hib.12`).
- **Fails if:** geocoding fails without the grant. That would mean the app's
  location entitlement has to come back, and
  `SingleLocationPromptTests.testTheAppHasNoLocationEntitlement` has to go.

### H. The menu bar never shows a stale number

With the helper off (E) or refused (F), leave the app running past the
1-hour soft TTL.

- **Expect:** the menu bar stops showing a number and shows `—`. It must
  never display a number old enough to mislead (`e70.31`).

### I. Widget stays fresh over hours, app never launched

Complete A, quit the app, place a **Current Location** widget, and leave the
machine for several hours.

- **Expect:** the widget keeps showing data that stays current. This is the
  entire reason the epic exists.
- **Fails if:** it goes to "Data Unavailable" while the helper is enabled
  and granted.

### J. Upgrade from the pre-helper build [fresh]

Install `…-PRE-HELPER.dmg` first. Launch it, grant it location the old way,
let it fetch, place a Current Location widget. **Then** install the helper
build over it.

- **Expect:** at most ONE new prompt (the helper's), and the explanation
  refers to the upgrade — that this update moves current-location updates
  into a background updater which needs its own permission, separate from
  the access already given. Pinned locations never break. The existing
  widget keeps rendering its pre-upgrade reading, visibly aged, rather than
  blanking.
- **Fails if:** the widget blanks the moment the upgrade lands (that would
  contradict `dc2.5`'s stale-while-revalidate), or the copy reads as a
  generic first-run rather than an upgrade.

### K. Does an update preserve Login Items approval? — OPEN QUESTION

This one has no predicted answer, which is why it is on the list.

Complete A so the item is approved. Then install a *newer* helper build over
it and relaunch.

- **What happens:** `LocationHelperController.reregisterIfBundleChanged()`
  notices the executable changed and re-registers. `register()` unregisters
  first, per `SMAppService.h`'s recommendation.
- **The question:** does the user's approval survive that? If it does not,
  every app update silently drops users into check E's state — which would
  be a *worse* failure than the stale registration re-registration prevents,
  and would mean preferring a plain re-`register()`.
- **Log:** `HELPER_REREGISTERING was=… now=…` then `HELPER_REGISTERED
  status=…`. A `status=requiresApproval` there is the bad answer.
- Context: re-registration exists because this failure was measured live on
  2026-09-02 — `last exit code = 78: EX_CONFIG`, `properties` including
  `needs LWCR update`, and launchd respawning every 10 seconds, 3,452 times
  in twelve hours, while `SMAppService.status` reported `.enabled`
  throughout.

### L. Uninstall leaves nothing behind

Complete A, then run **Uninstall BlueGull AQI.command** from the DMG.

- **Expect:** it reports "background updater: unregistered" *before*
  removing the app, and afterwards no row remains in Login Items &
  Extensions.
- **Verify:**
  ```bash
  launchctl print gui/$(id -u)/solutions.bluegull.aqi.locationhelper
  ```
  should report the service cannot be found.
- **Fails if:** the row survives. Order matters — `SMAppService.unregister()`
  resolves relative to `Bundle.main` and cannot run once the bundle is gone,
  and `launchctl bootout` stops a job without removing the record.

### M. Idle footprint

While the helper is registered and idle, check Activity Monitor.

- **Expect:** near-zero CPU, single-digit MB. The spike measured 2.9 MB and
  0.0% CPU.
- **Fails if:** CPU is continuously non-trivial — check `runs` in
  `launchctl print`. A climbing counter with no `PROCESS_START` lines is the
  spawn-failure loop from check K.

---

## 4. Already evidenced

These were established on real hardware during implementation. Re-run them
in the clean room if convenient, but they are not open questions.

| Claim | Evidence |
|---|---|
| Registration works from the real app | `HELPER_REGISTERED status=enabled`, 2026-09-01 |
| launchd demand-starts the agent via the app-group mach service | 0.3s from poke to `PROCESS_START`, 2026-09-01 |
| A headless launchd-started helper can obtain a location grant | `AUTH_CHANGED authorized`, then a fix, 2026-09-01 |
| The sandboxed helper can open the shared App Group | `appGroup=ok` |
| `CLGeocoder` needs no location authorization | zip resolved to a coordinate with the entitlement removed, `hib.12` |
| Re-registration repairs a stale record | 3,452-spawn loop → `runs = 1`, 2026-09-02 |
| Re-registration preserves the activity schedule | criteria stored verbatim; wake 20 min later, 2026-09-02 |
| The observing authorization path reports correctly | `AUTH_SETTLED status=authorized asking=false`, 569ms, 2026-09-02 |
| Uninstall action removes the BTM record | `launchctl` could not find the service afterwards, 2026-09-02 |

## 5. Recording results

Comment on `bluegull-aqi-hib.9` with the check letter, pass/fail, and the
log lines that show it. A pass with no evidence attached is worth about as
much as not running it — twice today a green UI sat on top of a broken
state, and only the log disagreed.
