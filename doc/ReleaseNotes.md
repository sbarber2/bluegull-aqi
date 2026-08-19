# Blue Gull AQI Release Notes

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
