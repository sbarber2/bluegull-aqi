/// Copy for labeling AirNow's real-time observations correctly
/// (bluegull-aqi-10h.18). These are NowCast AQI values -- EPA's endorsed
/// method for relating short-term data to the AQI, using a variable
/// averaging window (longer when air quality is stable, shorter when it's
/// changing fast: PM2.5 ~12h stable / ~3h variable, ozone ~8h stable / ~1h
/// variable). The value is a weighted average designed to track lived
/// experience -- NOT an instantaneous sensor reading, and NOT the daily AQI
/// agencies report for "yesterday" (which requires a full 24 hours). See
/// doc/DESIGN.md "What the number is: NowCast, not a spot reading".
///
/// UI code must use `headline` rather than inventing its own phrasing --
/// wording like "right now" or "current reading" implies a spot measurement
/// this value isn't. `ComplianceTests` guards against exactly that
/// regression.
///
/// A longer explanation of NowCast itself (for a detail/expand view
/// alongside the preliminary-data disclaimer) is deliberately not defined
/// here: placement and length are UI decisions for whichever task actually
/// builds that view (bluegull-aqi-e70.11, mtm.14), not this shared package.
public enum NowCastCopy {
    /// airnow.gov's own phrasing -- verified safe against the live site
    /// (see doc/DESIGN.md), and deliberately non-committal about timing
    /// ("current" here means "the latest available," not "this instant").
    public static let headline = "Current Air Quality"
}
