/// Pollutant display-name copy (bluegull-aqi-10h.20). From the AQI
/// Technical Assistance Document FAQ: "Based on focus group testing by
/// EPA, people better understand and prefer the term particle pollution
/// than particulate matter." A copy preference, not a requirement, but
/// worth following for an app whose purpose is public health
/// communication.
public enum PollutantCopy {
    /// The spelled-out display name for a pollutant, given AirNow's own
    /// `parameterName` value (`PollutantReading.parameterName`). "PM2.5" /
    /// "PM10" remain fine as compact labels where space is tight -- use
    /// `parameterName` directly for those, unchanged; this is only for the
    /// spelled-out form.
    ///
    /// Falls back to `parameterName` itself, unchanged, for any pollutant
    /// without a specific mapping here -- deliberately narrow in scope to
    /// what bluegull-aqi-10h.20 actually asked for (the "particle
    /// pollution" vs. "particulate matter" preference), not a general
    /// pollutant-name translation table this issue never requested.
    public static func spelledOutName(forParameterName parameterName: String) -> String {
        switch parameterName {
        case "PM2.5": return "Particle Pollution (PM2.5)"
        case "PM10": return "Particle Pollution (PM10)"
        default: return parameterName
        }
    }
}
