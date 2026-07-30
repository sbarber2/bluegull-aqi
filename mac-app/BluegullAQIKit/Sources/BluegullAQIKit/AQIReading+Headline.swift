public extension AQIReading {
    /// The pollutant reading that determines the overall reported AQI for
    /// this location -- the one with the highest `nowcastAQI`, matching
    /// AirNow's own methodology (the worst pollutant "drives" the reported
    /// AQI for an area). `AQIReading` deliberately doesn't pick this itself
    /// (see its own doc comment) -- originally added as an app-target-only
    /// extension (bluegull-aqi-e70.11), then moved here (bluegull-aqi-mtm.4)
    /// once the widget extension needed the exact same decision for its own
    /// per-family layouts -- no UI-framework dependency, so nothing about
    /// it actually required living outside the shared package once more
    /// than one UI target needed it.
    ///
    /// nil if there's no pollutant with a non-nil `nowcastAQI` to compare --
    /// an empty reading, or one where every entry supplied only a raw
    /// concentration (see `PollutantReading.nowcastAQI`'s doc comment).
    /// Never invents a value in that case.
    var headlinePollutant: PollutantReading? {
        pollutants
            .filter { $0.nowcastAQI != nil }
            .max { ($0.nowcastAQI ?? 0) < ($1.nowcastAQI ?? 0) }
    }
}
