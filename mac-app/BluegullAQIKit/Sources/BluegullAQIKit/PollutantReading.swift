/// One pollutant's reading, decoded directly from AirNow's
/// `current/ziplatlong` response shape -- one array entry per pollutant, for
/// either data-source client (`AirNowDirectClient`, bluegull-aqi-10h.3;
/// `BluegullServiceClient`, bluegull-aqi-10h.4). Field names and values are
/// AirNow's own, unaltered (bluegull-aqi-10h.17): this type never derives,
/// re-derives, or interpolates an AQI. Property names match AirNow's JSON
/// keys exactly (including `siteID`'s capitalization) so Codable synthesis
/// needs no custom CodingKeys and there's no risk of a silent field-mapping
/// mismatch.
public struct PollutantReading: Sendable, Equatable, Codable {
    public let dateObserved: String
    public let hourObserved: String
    public let localTimeZone: String
    public let reportingAreaName: String
    public let siteID: String
    public let siteName: String
    public let parameterName: String

    /// AirNow's own NowCast AQI for this pollutant. Optional to allow for a
    /// response that supplies a raw concentration without a computed AQI
    /// (bluegull-aqi-10h.17) -- not observed from the `ziplatlong` endpoint
    /// this project actually uses, but the type must not assume it's always
    /// present. Displaying a concentration-only reading appropriately is
    /// that task's job, not this type's.
    public let nowcastAQI: Int?
    public let aqiCategoryName: String
    public let reportingAgency: String
    public let lookupBehavior: String
    public let consideredMonitors: String
    public let lookupBoundary: String

    public init(
        dateObserved: String,
        hourObserved: String,
        localTimeZone: String,
        reportingAreaName: String,
        siteID: String,
        siteName: String,
        parameterName: String,
        nowcastAQI: Int?,
        aqiCategoryName: String,
        reportingAgency: String,
        lookupBehavior: String,
        consideredMonitors: String,
        lookupBoundary: String
    ) {
        self.dateObserved = dateObserved
        self.hourObserved = hourObserved
        self.localTimeZone = localTimeZone
        self.reportingAreaName = reportingAreaName
        self.siteID = siteID
        self.siteName = siteName
        self.parameterName = parameterName
        self.nowcastAQI = nowcastAQI
        self.aqiCategoryName = aqiCategoryName
        self.reportingAgency = reportingAgency
        self.lookupBehavior = lookupBehavior
        self.consideredMonitors = consideredMonitors
        self.lookupBoundary = lookupBoundary
    }

    /// `nowcastAQI` mapped to the official TAD category table
    /// (bluegull-aqi-10h.16 covers `> 500`) -- nil when `nowcastAQI` itself
    /// is nil, or when it's present but negative (malformed data, not a
    /// valid "beyond the scale" reading -- see AQICategory.init(aqi:)).
    /// Deliberately NOT derived from `aqiCategoryName` (AirNow's own
    /// category string): this type is the single place that interprets the
    /// numeric value against the TAD table, so the two never have a chance
    /// to disagree with each other.
    public var category: AQICategory? {
        nowcastAQI.flatMap(AQICategory.init(aqi:))
    }
}
