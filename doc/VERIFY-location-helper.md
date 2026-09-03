# Verifying the location helper agent

Manual verification for the `bluegull-aqi-hib` epic (`hib.9`).

Almost nothing in this epic is unit-testable. launchd lifecycle, TCC grants,
XPC Activity scheduling and background-item revocation are all OS
integration, and the interesting failures are *silent* — a login item that
still says "enabled" while the agent never runs, a permission recorded as
absent while it is present. Every such failure so far was found by reading
the unified log on a live machine, never by a test. This document exists so
that reading is systematic rather than lucky.

Also published as a page, for reading on the host while operating the VM:
<https://claude.ai/code/artifact/92b57b49-a02f-4020-8ae7-e5345993b11c>
(this file is the source of truth; update it first).

Companion to `doc/DEVINSTALL.md`. Same spirit as the manual checks in
`bluegull-aqi-e70.8` and `mtm.9`.

---

## 1. Where each check runs

Two environments, split by what a check *costs* rather than by convenience.

**In the VM — anything that spends something you cannot get back.** The
location grant is one shot and unremovable: CoreLocation refuses to re-prompt
once answered, and the record cannot be cleared — `tccutil` has no authority
over locationd and fails `-10814`. On real hardware every clean first-run
test therefore burns a bundle identifier permanently, which is why the spike
had to burn `solutions.bluegull.hib10.locprobe1`. Reverting a snapshot is the
only reset that exists.

**On the host — anything reversible.** The development Mac already has a
granted, working helper, so these add no new TCC or Background Task
Management state beyond what is already there. They are just running the app.

| Check | Where | Why |
|---|---|---|
| A — one prompt on clean install | **VM** | burns a grant |
| B — "Not now" is free | **VM** | needs a virgin, undecided state |
| C — refreshes with the app quit | host | needs a real location fix |
| D — reboot, not login-scoped | host | needs a real fix, and a reboot you don't mind |
| E — background item switched off | host | reversible; switch it back on |
| F — refusing is handled honestly | **VM** | burns the grant, permanently |
| G — pinned locations never break | either | needs no grant at all |
| H — no stale number in the menu bar | host | reversible |
| I — widget fresh over hours | host | needs a real fix and hours of wall clock |
| J — upgrade from pre-helper | **VM** | burns a grant, and installs an old build |
| K — approval across an update | **VM** | mutates the BTM record |
| L — uninstall leaves nothing | **VM** | destructive; trivial to redo from a snapshot |
| M — idle footprint | host | observation only |

### Does CoreLocation work in the VM?

Worth knowing, but it no longer gates the plan — the checks that need a real
coordinate are on the host precisely because the VM may not be able to
produce one. A VM has no Wi-Fi radio and Mac positioning leans on Wi-Fi
scanning, so a guest may show the permission prompt perfectly and never get a
fix.

Two minutes, once: open Maps in the guest and press the current-location
arrow. Record the answer on `bluegull-aqi-hib.14`.

If it cannot fix, the VM checks still stand — A, B, F, J and K are about
prompts, counts, states and copy. Where one of them also expects a *reading*,
that half simply moves to the host; the doc flags those below. A VM that
cannot resolve location is not an app failure and must not be recorded as one.

---

## 2. Working in the VM

**Snapshot before first launch, and revert before every check marked
[fresh].** That snapshot is the entire reason the VM exists.

On APFS, duplicating a VM bundle is a copy-on-write clone — instant, and it
shares storage with the original until the copy diverges. `cp -c`, or
Duplicate in Finder. So "pristine plus N runs" costs roughly one image plus
what each run actually writes, not N images. Keep the pristine copy
untouched and always work on a clone.

**Getting a build in.** `make app-package` staples the notarization ticket,
so the DMG installs in the guest with no network round trip and no Apple ID
sign-in. A shared folder or a drag into the VM window is enough.

**Do not suspend the VM during a time-based check.** launchd's activity
scheduling runs on wall clock while the machine is awake; a suspended guest
accrues nothing. This is one more reason C, D and I live on the host.

**Storage note.** The VM image lives on the T9 volume, so the volume has to
be mounted before any of this. Worth confirming first rather than
discovering it three steps in.

---

## 3. What you need

- The clean macOS 26.x VM, snapshotted before first launch.
- The **pre-helper** build, for check J — v0.2.1 build 228, commit
  `de24af6` (= `main`), notarized, containing no
  `Contents/Library/LoginItems`:
  `~/BlueGull-verification/BluegullAQI-0.2.1-228-de24af6-PRE-HELPER.dmg`
  (also recoverable from the GitHub releases).
- The **helper** build: `make app-package` on this branch, v0.3.0.
- Both must be notarized Developer ID. An Apple Development build is a
  different signing identity and will not tell you what a user sees.

**Exactly one `BluegullAQI.app` must exist at a time.** Confirmed the hard
way on 2026-09-02 (`hib.17`): a stale v0.2.1 left in `/Applications`
alongside a dev build fought it over the bundle id, the App Group and the
`bluegullaqi://` scheme — the old one won the widget's deep link, prompted
for location on every launch, and exited. Before and after any install step:

```bash
mdfind "kMDItemCFBundleIdentifier == 'solutions.bluegull.aqi'"
```

---

## 4. Reading the instrumentation

```bash
/usr/bin/log stream --predicate 'subsystem == "solutions.bluegull.aqi"'

/usr/bin/log show --last 30m --predicate 'subsystem == "solutions.bluegull.aqi"'

launchctl print gui/$(id -u)/solutions.bluegull.aqi.locationhelper
```

**Two traps that have each cost real time:**

- **`log` is a zsh builtin.** Where it is shadowed, `log show …` fails with
  "too many arguments". Use `/usr/bin/log` explicitly.
- **`--last` can return nothing after a reboot** while `--start` with an
  absolute timestamp returns everything. Found during `hib.10`, where it
  nearly produced a false negative on the most important measurement.

Logging is at `.notice`, **not** `.debug`, deliberately. `hib.9` originally
specified `.debug`; that is wrong for this process. `.debug` is memory-only
and gone by the time you read it after a reboot — which is exactly check D.

In `launchctl print`, read `state`, `runs`, `last exit code` and
`properties`. `needs LWCR update` means the Background Task Management
record pins a code requirement the current executable no longer satisfies —
see check K.

**Identifying who is prompting.** The app and the helper both display as
"BlueGull AQI", so the dialog alone will not tell you which asked. The
answer is in the log:

```bash
/usr/bin/log show --last 10m --predicate 'process == "CoreLocationAgent"' | grep auth-prompt
```

then resolve the pid it names. A prompt from `BluegullAQI` rather than
`BluegullAQIHelper` means something is wrong: under `hib.6` the app holds no
location entitlement and cannot legitimately ask.

---

## 5. The checks

Revert the VM snapshot before any check marked **[fresh]**.

### A. Clean install, first run — exactly one prompt — **VM** [fresh]

Install the helper DMG, launch, and count permission prompts from launch
through first data.

- **Expect:** the Background Updates window opens by itself. Clicking
  **Turn On** produces exactly ONE system location prompt, attributed to
  **BlueGull AQI**. Approving it yields a green "You're all set".
- **Read the prompt.** The title must render completely, not truncate at
  "would like to use" — that truncation was seen on the old build
  (`hib.17`) and the helper's prompt uses the same display name, so it has
  never been confirmed to render cleanly.
- **Fails if:** two prompts appear (the app must never ask — that is what
  removing its location entitlement enforces), or the prompt names anything
  other than BlueGull AQI, or it appears before you clicked Turn On.
- **Log:** `HELPER_REGISTERED` → `PROCESS_START … appGroup=ok` →
  `AUTH_REQUESTING` → `AUTH_SETTLED status=authorized asking=true` →
  `REFRESH reason=first-run`.
- `AUTH_SETTLED` should follow your click by well under a second. Near
  exactly 120s means the delegate callback never arrived and only the
  deadline's fallback noticed — the regression fixed in `7a8d048`.
- **If the VM cannot fix location:** the prompt count, the attribution, the
  wording and `AUTH_SETTLED status=authorized` are all still valid here.
  `REFRESH` will report no reading; that is the environment, not the app.

### B. "Not now" costs nothing and is re-askable — **VM** [fresh]

Same as A, but click **Not now**.

- **Expect:** no system prompt at all. The popover offers "Turn On
  Background Updates" indefinitely. Clicking it later still works, and only
  then produces the one prompt.
- **Fails if:** a system prompt appeared anyway, or the offer disappears.
- Cheap and non-destructive — no grant is spent, so this one can be repeated
  in the same snapshot until you are satisfied.

### C. The helper refreshes with the app quit — **host**

Complete first-run setup on the host (already done, 2026-09-01), then
**Quit BlueGull AQI**. Leave it an hour.

- **Expect:** `PROCESS_START` / `REFRESH` lines with the app not running.
  `ppid=1` — launchd started it, nothing else could have.
- Cadence is `Interval 1800` + `Delay 300` + `GracePeriod 900`, so the first
  wake may legitimately be ~20 minutes and later ones up to ~45 apart.
  Measured 2026-09-02: registered 08:37, first wake 08:57.
- `outcome=skipped-still-fresh` is a **pass**, not a miss — the slot was
  inside its 3600s soft TTL, and skipping is what keeps a 30-minute interval
  from costing extra requests.

### D. Reboot, and the agent is NOT login-scoped — **host**

Quit the app, reboot, and **do not launch the app**.

- **Expect:** the helper eventually wakes on its own. The plist carries no
  `RunAtLoad` and no `KeepAlive`, so anything that runs it is launchd acting
  on the activity.
- **Fails if:** it only ever runs right at login (the activity is not
  surviving), or never runs at all.
- Remember the `--last` trap when reading the log after a reboot.

### E. Background item switched off — detected, explained, recoverable — **host**

System Settings → General → Login Items & Extensions → switch
**BlueGull AQI** off. Switch it back on afterwards.

- **Expect:** within one refresh cycle the popover says background updates
  were turned off, offers a working "Turn On", and states that locations
  added by name still work. The widget agrees. Neither surface shows a
  fresher number than the other.
- **Fails if:** the app carries on as if nothing happened — there is no
  notification for this; detection is by polling `SMAppService.status` — or
  the two surfaces disagree.

### F. Refusing the prompt is handled honestly — **VM** [fresh]

Fresh install, **Turn On**, then **Don't Allow**.

- **Expect:** the app says location is off for BlueGull AQI, that macOS only
  asks once, and points at System Settings → Privacy & Security → Location
  Services, with a button that opens it. It must NOT offer to ask again —
  CoreLocation would silently ignore that.
- **This is the check the VM exists for.** On the host it would permanently
  destroy the helper's grant with no way back.

### G. Pinned locations never break — **either**

Throughout, and especially with location refused (F) or background updates
off (E): add a location by zip code in Settings.

- **Expect:** it resolves to a coordinate and fetches. Pinned locations need
  no location grant at all — `CLGeocoder` needs network access, not
  authorization (confirmed 2026-09-02, `hib.12`).
- **Fails if:** geocoding fails without the grant. That would mean the app's
  location entitlement has to come back, and
  `SingleLocationPromptTests.testTheAppHasNoLocationEntitlement` has to go.

### H. The menu bar never shows a stale number — **host**

With the helper off (E), leave the app running past the 1-hour soft TTL.

- **Expect:** the menu bar stops showing a number and shows `—`. It must
  never display a number old enough to mislead (`e70.31`).

### I. Widget stays fresh over hours, app never launched — **host**

Quit the app, place a **Current Location** widget, and leave the machine for
several hours. Do not let it sleep for the whole window.

- **Expect:** the widget keeps showing data that stays current. This is the
  entire reason the epic exists.
- **Fails if:** it goes to "Data Unavailable" while the helper is enabled
  and granted.

### J. Upgrade from the pre-helper build — **VM** [fresh]

Install `…-PRE-HELPER.dmg` first. Launch it, grant it location the old way,
let it fetch, place a Current Location widget. **Then** install the helper
build over it — replacing it, not alongside it (see `hib.17`).

- **Expect:** at most ONE new prompt (the helper's), and the explanation
  refers to the upgrade — that this update moves current-location updates
  into a background updater which needs its own permission, separate from
  the access already given. Pinned locations never break. The existing
  widget keeps rendering its pre-upgrade reading, visibly aged, rather than
  blanking.
- **Confirm afterwards** that only one `BluegullAQI.app` exists.
- **Fails if:** the widget blanks the moment the upgrade lands (that would
  contradict `dc2.5`'s stale-while-revalidate), or the copy reads as a
  generic first run rather than an upgrade.
- **If the VM cannot fix location:** the old build will not have a reading to
  age, so the widget half of this check moves to the host. The prompt count
  and the upgrade copy — the parts this check exists for — still hold.

### K. Does an update preserve Login Items approval? — **VM** [fresh]

This one has no predicted answer, which is why it is on the list.

Complete A so the item is approved. Then install a *newer* helper build over
it and relaunch.

- **What happens:** `reregisterIfBundleChanged()` notices the executable
  changed and re-registers. `register()` unregisters first, per
  `SMAppService.h`'s recommendation.
- **The question:** does the user's approval survive that? If it does not,
  every app update silently drops users into check E's state — a *worse*
  failure than the stale registration re-registration prevents, and it would
  mean preferring a plain re-`register()`.
- **Log:** `HELPER_REREGISTERING was=… now=…` then `HELPER_REGISTERED
  status=…`. A `status=requiresApproval` there is the bad answer.
- Context: this exists because the failure was measured live on 2026-09-02 —
  `last exit code = 78: EX_CONFIG`, `properties` including `needs LWCR
  update`, and launchd respawning every 10 seconds, 3,452 times in twelve
  hours, while `SMAppService.status` reported `.enabled` throughout.
- Needs no location fix — it is entirely about `SMAppService` state.

### L. Uninstall leaves nothing behind — **VM**

Run **Uninstall BlueGull AQI.command** from the DMG.

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

### M. Idle footprint — **host**

While the helper is registered and idle, check Activity Monitor.

- **Expect:** near-zero CPU, single-digit MB. The spike measured 2.9 MB and
  0.0% CPU.
- **Fails if:** CPU is continuously non-trivial — check `runs` in
  `launchctl print`. A climbing counter with no `PROCESS_START` lines is the
  spawn-failure loop from check K.

---

## 6. Already evidenced

Established on real hardware during implementation. Re-run in the clean room
if convenient, but these are not open questions.

| Claim | Evidence |
|---|---|
| Registration works from the real app | `HELPER_REGISTERED status=enabled`, 09-01 |
| launchd demand-starts the agent via the app-group mach service | 0.3s poke → `PROCESS_START`, 09-01 |
| A headless launchd-started helper can obtain a location grant | `AUTH_CHANGED authorized`, then a fix, 09-01 |
| The sandboxed helper can open the shared App Group | `appGroup=ok` |
| `CLGeocoder` needs no location authorization | zip → coordinate with the entitlement removed, `hib.12` |
| Re-registration repairs a stale record | 3,452-spawn loop → `runs = 1`, 09-02 |
| Re-registration preserves the activity schedule | criteria verbatim; wake +20 min, 09-02 |
| The observing authorization path reports correctly | `AUTH_SETTLED authorized`, 569 ms, 09-02 |
| Uninstall action removes the BTM record | service not found afterwards, 09-02 |

## 7. Recording results

Comment on `bluegull-aqi-hib.9` with the check letter, the environment it ran
in, pass or fail, and the log lines that show it. A pass with no evidence
attached is worth about as much as not running it — twice on 2026-09-02 a
green UI sat on top of a broken state, and only the log disagreed.
