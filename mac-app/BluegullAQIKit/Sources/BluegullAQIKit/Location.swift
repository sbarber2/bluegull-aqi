/// A geographic coordinate used to request AQI data. Deliberately minimal --
/// resolving a coordinate to a human-readable place name is
/// `LocationResolver`'s job (bluegull-aqi-10h.6), not this type's.
public struct Location: Sendable, Equatable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
