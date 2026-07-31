# Running BlueGull AQI locally

The menu bar app (`mac-app/BluegullAQI.xcodeproj`) can be built and run
entirely from your own Mac, with no AWS dependency, using **Direct mode**
(the client calls AirNow directly with your own API key). Service mode
(the AWS-backed proxy) isn't available until `bluegull-aqi-q9r.10` and
`bluegull-aqi-10h.4` land.

## Install / run

1. **Open the project in Xcode:**

   ```bash
   open mac-app/BluegullAQI.xcodeproj
   ```

   It's already generated and committed — no need to run `xcodegen`
   first unless you've edited `mac-app/project.yml`.

2. **Make sure Xcode is signed into the right Apple ID** — the one used
   to register the `solutions.bluegull.aqi` bundle IDs and App Group
   (`bluegull-aqi-8ef.5`). Xcode → Settings → Accounts. Signing is
   `Automatic`, and this app uses App Sandbox + App Groups, so it needs to
   actually sign successfully to launch at all.

3. **Select the `BluegullAQI` scheme** (the default) and press **Cmd+R**.

4. **Look in the menu bar, not a window** — it's `LSUIElement: true` (no
   Dock icon, no main window, by design). You'll see either a generic AQI
   icon (no data yet) or, once it has a reading, a colored dot + number.

5. **Grant location access** when macOS prompts you.

6. **Switch to Direct mode**: click the menu bar icon → gear icon →
   Settings → "Data Source" → **Direct (use my own AirNow key)** → paste
   in your AirNow API key → Save. Service mode is still the default and
   won't work yet.

   If you don't already have your own personal AirNow key (separate from
   the service's own key in AWS SSM), register for one free at
   `airnowapi.org`.

Once the key is saved and location access is granted, the app should
fetch within a few seconds and show a real reading in both the menu bar
and the popover.

## Uninstall (leave no trace)

App Sandbox writes to a few places macOS doesn't clean up automatically
when you just delete the app bundle.

1. **Remove the widget from your desktop first**, if you added one —
   right-click it → Remove Widget. Otherwise it can dangle after the host
   app is gone.

2. **Quit the app.** No Dock icon — quit from the menu bar icon, or stop
   it from Xcode if you're running it via Cmd+R. It's not a login item
   (nothing registers one), so it won't relaunch itself.

3. **Delete the app bundle:**
   - If running via Xcode (Cmd+R), it lives in DerivedData, not
     `/Applications` — delete the whole build folder:
     `~/Library/Developer/Xcode/DerivedData/BluegullAQI-*`
   - If you archived/exported it to `/Applications`, drag it to Trash and
     empty Trash.

4. **Clear the Keychain item** — this is the one that matters most, since
   it's iCloud-synced and would otherwise linger across your other Macs.
   Easiest: while the app still exists, open Settings → "Clear" next to
   the AirNow API key, *before* deleting the app bundle. If you've
   already deleted the app: open Keychain Access.app, search
   `solutions.bluegull.aqi`, delete the item you find there.

5. **Delete stored preferences and cache:**

   ```bash
   defaults delete solutions.bluegull.aqi 2>/dev/null
   rm -rf ~/Library/Group\ Containers/group.solutions.bluegull.aqi
   ```

   The first clears your data-source mode setting; the second clears the
   App Group container (AQI cache, pinned locations, refresh-schedule
   state) shared between the app and widget.

6. **Reset the location permission grant:**

   ```bash
   tccutil reset Location solutions.bluegull.aqi
   ```

   macOS's TCC permission database isn't touched by deleting the app
   itself — this explicitly revokes the grant.

That covers everything the code actually writes — no other files, no
other Keychain items, nothing else on disk.
