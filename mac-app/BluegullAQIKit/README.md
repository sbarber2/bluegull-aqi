# BluegullAQIKit

Swift package shared by the BlueGull AQI menu bar app and widget extension.
See [`/doc/DESIGN.md`](../../doc/DESIGN.md) for the full design.

**Status**: shared models (`Location`, `PollutantReading`, `AQIReading`,
`AQICategory`/`AQIColor`) are done. Clients, Keychain helper, location
resolver, and cache are separate tracked tasks — `bd dep tree bluegull-aqi-10h`.

```bash
swift build
swift test
```
