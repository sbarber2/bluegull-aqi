import Foundation

/// Turning AirNow's split observation fields into a real timestamp, and into
/// the absolute display string surfaces use once a reading is old enough to
/// need qualifying (bluegull-aqi-dc2.7).
///
/// AirNow reports observation time as three separate strings --
/// `dateObserved` ("2026-08-11"), `hourObserved` ("17:00") and
/// `localTimeZone` ("EDT") -- rather than one instant, so anything wanting to
/// display or compare it has to reassemble it first.
public extension PollutantReading {
    /// The instant the air was actually measured, or nil if AirNow's fields
    /// couldn't be parsed. Deliberately NOT the time we fetched the reading:
    /// AirNow publishes roughly hourly, so a just-fetched reading is commonly
    /// already 30-60 minutes old by observation, and conflating the two
    /// overstates how current the data is.
    var observedAt: Date? {
        // "H" (not "HH"): a real 2026-08-05 AirNow response for Boston Metro
        // (bluegull-aqi-10h.21's fixture) has hourObserved "7:00", not
        // "07:00" -- DateFormatter's "HH" requires two digits and silently
        // fails to parse a single-digit hour, so this would return nil for
        // roughly a third of the day's observations if written that way. A
        // bare-hour fallback (no ":mm") guards against a shape without
        // minutes that hasn't been seen yet but isn't documented against.
        for format in ["yyyy-MM-dd H:mm", "yyyy-MM-dd H"] {
            let formatter = DateFormatter()
            // Fixed POSIX locale -- this parses machine-formatted input, so it
            // must not follow the user's locale or calendar.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(abbreviation: localTimeZone) ?? .current
            formatter.dateFormat = format
            if let date = formatter.date(from: "\(dateObserved) \(hourObserved)") {
                return date
            }
        }
        return nil
    }

    /// Absolute, human-readable observation time -- e.g. "Tue Aug 12, 5:00 PM
    /// EDT". Never relative ("3 hours ago"): Steve's requirement
    /// (bluegull-aqi-dc2.7) is that an aged reading state plainly *when* it is
    /// from, because a relative phrase is vague at exactly the moment
    /// precision matters.
    ///
    /// Rendered in the observation's own reporting time zone rather than the
    /// viewer's, so it matches the `localTimeZone` suffix and stays meaningful
    /// for a widget pinned to a location in another zone. Fixed `en_US` locale
    /// for the same golden-image determinism reason the widget's other copy
    /// uses one (bluegull-aqi-mtm.11) -- and unlike the relative formatting it
    /// replaces, this is stable regardless of when the snapshot is rendered.
    var observedAtDisplay: String? {
        guard let observedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(abbreviation: localTimeZone) ?? .current
        formatter.dateFormat = "EEE MMM d, h:mm a zzz"
        return formatter.string(from: observedAt)
    }
}
