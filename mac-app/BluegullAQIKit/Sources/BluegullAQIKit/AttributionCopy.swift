/// Attribution copy shared by both UI targets -- the menu bar popover
/// (bluegull-aqi-e70.10) and the widget's tap-to-expand detail view
/// (bluegull-aqi-mtm.14) -- so the two never drift on wording. Same
/// rationale as `PollutantCopy`/`NowCastCopy`.
public enum AttributionCopy {
    /// The second, static tier of the two-tier attribution the AirNow Data
    /// Exchange Guidelines require: credit to AirNow/EPA itself, shown
    /// regardless of whether a specific reporting agency is also available
    /// (`PollutantReading.attributionText`, the first tier -- see its own
    /// doc comment and bluegull-aqi-10h.15). Always shown alongside the
    /// first tier when present, and shown alone as the fallback when it
    /// isn't -- never omitted.
    ///
    /// Styled after the airnow.gov precedent (its own "EPA and PARTNERS"
    /// logo lockup, checked live 2026-07-28 -- see doc/DESIGN.md "AirNow
    /// terms review") as a text equivalent; no EPA logo asset is used here.
    public static let staticCredit = "Air quality data from the EPA AirNow program"

    /// The in-product preliminary-data disclaimer the AirNow Data Exchange
    /// Guidelines require ("the analysis results, displays, or products
    /// must indicate that these data are preliminary") -- see
    /// bluegull-aqi-dc2.4 and doc/DESIGN.md "AirNow terms review" finding
    /// 2. Wording confirmed by Steve 2026-07-31, derived directly from the
    /// guideline text rather than the iOS app's unrecorded precedent.
    public static let preliminaryDataDisclaimer = "Data are preliminary and have not been fully verified or validated."
}
