/// Shared package for the BlueGull AQI menu bar app and widget extension.
///
/// Models, both AirNow data-source clients, the Keychain helper, location
/// resolution, and the App Group shared cache all live here so neither UI
/// target duplicates logic or drifts from the other. See doc/DESIGN.md.
public enum BluegullAQIKit {
    public static let version = "0.1.0"
}
