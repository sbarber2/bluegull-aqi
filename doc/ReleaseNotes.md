# Blue Gull AQI Release Notes

## 0.2.1 — 2026-08-29

### Added

- Optional "Launch BlueGull AQI at login" toggle in Settings
- "Completely Remove BlueGull AQI…" button in Settings for a one-click uninstall
  — clears all settings, cached data, and the saved AirNow API key
- The release DMG now includes standalone Uninstall and Kill-All-Processes
  utilities alongside the app, for when it isn't currently running

### Changed

- Settings panel background is now a flat color instead of a gradient, for more
  reliable contrast throughout
- Settings panel is more compact, with tighter spacing between the app-behavior
  toggles

### Fixed

- Settings window could reopen at an oversized or off-screen size after
  upgrading from an older version

## 0.2.0 — 2026-08-25

### Added

- Widget faces (all three sizes) now show a colored AQI category scale with a marker
  for the current reading, over a new Blue Gull-branded gradient background instead
  of the plain system background
- The menu bar popover and Air Quality Detail window now use the same branded
  background and color treatment as the widgets, for visual consistency across the
  whole app
- Widget faces now label the number "AQI" instead of showing a bare, unlabeled figure

### Changed

- Settings panel is narrower and uses the same branded background; its text fields,
  buttons, and toggles now use a themed style instead of stock white/checkbox
  controls
- Pinned Locations list is now scrollable instead of growing the window indefinitely
  as more locations are added

### Fixed

- Settings panel is no longer excessively wide
- The explanatory text above Pinned Locations now wraps instead of getting cut off

## 0.1.2 — 2026-08-25

### Added

- Both the menu bar popover and the widget detail window now show when a reading was
  observed and when this app itself last updated it — exact date, time, and time
  zone, plus a live relative time (e.g. "2 hours ago")

### Changed

- Attribution and the preliminary-data disclaimer are now shown as one combined
  paragraph instead of separate stacked lines
- The app now talks to the production backend instead of the development backend
  by default

### Fixed

- The Air Quality Detail window now updates live while left open, instead of
  freezing at whatever it showed when it was opened
- Pinned-location widgets could sit showing stale data for up to 3 hours without
  refreshing even after being flagged as aged — they now refetch as soon as they
  go stale, rather than waiting for a full expiry

## 0.1.1 — 2026-08-23

### Fixed

- Menu bar and widgets no longer wait up to a full hour to retry after a fetch failure
  — a failed fetch now retries with a backoff (60s, 120s, then holding at 4 minutes)
  for up to ~19 minutes before falling back to the normal hourly schedule, so a
  transient backend or upstream AirNow hiccup clears without an extended stretch of
  "Data Unavailable"

## 0.1.0 — 2026-08-19

- Changes since 2026-08-11 pre-release (which was inaccurately versioned as 1.0)

### Added

- Reverse-geocoded place name shown alongside Current Location, on both the menu bar
  and widget, including detail panels
- Staleness indicator on aged widget readings and in the Air Quality Detail popup,
  showing the absolute observation date/time instead of vague relative phrasing
  ("X hours ago")
- Configurable per-source request timeout: Direct and Service modes each get their
  own independently adjustable timeout in Settings. Service mode's default also
  bumps from 10s to 15s to give Lambda cold starts room to finish
- Settings redesigned as tabs by data source — Direct shows its API key field (which
  also no longer grabs default focus) and timeout stepper, Service shows a short
  explanatory note and its own timeout stepper
- Optional AQI number label next to the bare menu bar figure (e.g. "AQI 45"), off by
  default, toggle in Settings
- Real version numbers (marketing version + build number + git SHA) on built packages

### Changed

- Menu bar AQI category now shown as a colored pill instead of a dot
- Switching data source mode (Direct/Service) refetches immediately instead of
  waiting for the next cycle
- Service-mode fetch failures now show honest, source-accurate error messages
- Popover error banner wraps long text instead of truncating it

### Fixed

- Menu bar no longer shows a stale AQI number once a reading ages past its
  freshness window — falls back to an icon-only state instead
- Widget "Current Location" no longer gets stuck showing permanent Data Unavailable
- Menu bar location selection now falls back correctly instead of failing on a raw
  string mismatch
- Menu bar and widgets now flag the displayed reading as aged when the active fetch
  is failing, even if it's still within its normal freshness window
- WidgetKit is nudged to reload after a failed fetch, not just a successful one
- Service backend now falls back to serving stale cached data on an AirNow read
  timeout, instead of returning an unhandled 500 error
- DMG background: fixed arrow/icon overlap and clipped install instructions
