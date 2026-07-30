/// A geographic coordinate used to request AQI data. Deliberately minimal --
/// resolving a coordinate to a human-readable place name is
/// `LocationResolver`'s job (bluegull-aqi-10h.6), not this type's.
public struct Location: Sendable, Equatable, Hashable, Codable {
    /// Matches the server's own cache-key rounding precision
    /// (`LOCATION_KEY_PRECISION` in `cache.py`) -- 2 decimal degrees of
    /// latitude is ~1.1km. Kept in sync deliberately: rounding to the same
    /// grid on both ends maximizes cache-hit-rate alignment, not just
    /// privacy (bluegull-aqi-10h.11).
    private static let roundedPrecision = 100.0  // 10^2

    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Rounds to ~1km precision -- privacy by design, and free: AirNow
    /// resolves to the nearest monitoring station regardless, so this loses
    /// no real accuracy (bluegull-aqi-10h.11). Every network client in this
    /// package must round to this before a request leaves the device, so
    /// the server -- Direct mode's AirNow, or the BlueGull backend in
    /// Service mode -- never receives a precise location at all, not even
    /// transiently in a request log.
    public var rounded: Location {
        Location(
            latitude: (latitude * Self.roundedPrecision).rounded() / Self.roundedPrecision,
            longitude: (longitude * Self.roundedPrecision).rounded() / Self.roundedPrecision
        )
    }
}
