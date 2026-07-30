/// The full set of pollutant readings for one location/lookup -- the common
/// shape both data-source clients (`AirNowDirectClient`, bluegull-aqi-10h.3;
/// `BluegullServiceClient`, bluegull-aqi-10h.4) produce, so callers don't
/// care which one answered.
///
/// Deliberately does not pick a single "headline" pollutant/AQI to display --
/// that's a UI-facing decision (which task renders "the AQI number" for a
/// location, e.g. bluegull-aqi-e70.11's popover), not this shared model's
/// job. This type just holds what AirNow returned.
public struct AQIReading: Sendable, Equatable, Codable {
    public let location: Location
    public let pollutants: [PollutantReading]

    public init(location: Location, pollutants: [PollutantReading]) {
        self.location = location
        self.pollutants = pollutants
    }
}
