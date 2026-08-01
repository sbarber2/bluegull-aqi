import Foundation

/// Official EPA AQI category thresholds, colors, and descriptors -- verbatim
/// from the AQI Technical Assistance Document (EPA 454/B-18-007, Sept 2018),
/// Tables 1 and 2. A single shared mapping so neither UI target (menu bar
/// app, widget) defines this separately and risks drifting from the spec or
/// from each other. See doc/DESIGN.md "AQI Technical Assistance Document &
/// API Fact Sheet -- review findings".
public enum AQICategory: Sendable, Equatable, Codable {
    case good
    case moderate
    case unhealthyForSensitiveGroups
    case unhealthy
    case veryUnhealthy
    case hazardous
    /// AQI > 500. Rare but real, reported data (bluegull-aqi-10h.16) -- NOT
    /// an error state. The TAD: a value "can still be computed to indicate
    /// relative magnitude" using the Hazardous breakpoints, and the
    /// Hazardous recommendations still apply.
    case beyondAQI

    /// Maps an AQI value to its category per TAD Table 1, or nil if `aqi` is
    /// negative. `aqi` must be a value AirNow itself returned -- never
    /// computed from a concentration (bluegull-aqi-10h.17).
    ///
    /// A negative value is malformed data (a parse or transport fault), NOT
    /// a "beyond the scale" reading -- those are two different failure
    /// modes and bluegull-aqi-10h.16 is explicit that they must not be
    /// conflated. Returning nil here forces the caller to treat a negative
    /// value as an error state rather than silently rendering it with the
    /// Hazardous/beyond-scale styling.
    ///
    /// Deliberately does NOT attempt to flag an implausibly large *positive*
    /// value as malformed: disseminating AirNow's data as received
    /// (bluegull-aqi-10h.17) means not second-guessing its magnitude past
    /// this one well-defined, unambiguous boundary. Real extreme events
    /// have been reported this way -- e.g. Oregon DEQ recorded readings
    /// "well over 500" during the 2020 wildfires -- so inventing an upper
    /// cutoff risks blanking the app during exactly the conditions its
    /// users need it most.
    public init?(aqi: Int) {
        guard aqi >= 0 else { return nil }
        switch aqi {
        case 0...50: self = .good
        case 51...100: self = .moderate
        case 101...150: self = .unhealthyForSensitiveGroups
        case 151...200: self = .unhealthy
        case 201...300: self = .veryUnhealthy
        case 301...500: self = .hazardous
        default: self = .beyondAQI  // > 500 (bluegull-aqi-10h.16) -- real, valid data
        }
    }

    /// True only for `.beyondAQI` -- lets UI code decide whether to show
    /// `beyondScaleNotice` alongside the (shared) Hazardous styling.
    public var isBeyondScale: Bool { self == .beyondAQI }

    /// AirNow's own phrasing, verbatim from its AQI Legend panel -- not
    /// invented wording (bluegull-aqi-10h.16 is explicit about this). nil
    /// for every category except `.beyondAQI`.
    public var beyondScaleNotice: String? {
        self == .beyondAQI ? "Values above 500 are beyond the AQI scale" : nil
    }

    /// The full descriptor text. "Unhealthy for Sensitive Groups" is the
    /// full form; "USG" (AirNow's own abbreviation, seen on airnow.gov's
    /// legend) is acceptable only where space genuinely requires it --
    /// callers choose that abbreviation, this type does not offer it.
    public var descriptor: String {
        switch self {
        case .good: return "Good"
        case .moderate: return "Moderate"
        case .unhealthyForSensitiveGroups: return "Unhealthy for Sensitive Groups"
        case .unhealthy: return "Unhealthy"
        case .veryUnhealthy: return "Very Unhealthy"
        case .hazardous: return "Hazardous"
        case .beyondAQI: return "Hazardous"  // TAD: follow Hazardous recommendations
        }
    }

    /// TAD Table 1/2 color, verbatim. GOTCHA (the most likely failure mode
    /// here): Good is (0,228,0), NOT (0,255,0); Hazardous/BeyondAQI is
    /// (126,0,35), not a generic dark red.
    public var color: AQIColor {
        switch self {
        case .good: return AQIColor(red: 0, green: 228, blue: 0)
        case .moderate: return AQIColor(red: 255, green: 255, blue: 0)
        case .unhealthyForSensitiveGroups: return AQIColor(red: 255, green: 126, blue: 0)
        case .unhealthy: return AQIColor(red: 255, green: 0, blue: 0)
        case .veryUnhealthy: return AQIColor(red: 143, green: 63, blue: 151)
        case .hazardous, .beyondAQI: return AQIColor(red: 126, green: 0, blue: 35)
        }
    }
}

/// Explicit sRGB color, one byte (0-255) per channel -- matches how the TAD
/// publishes these values. Deliberately not a SwiftUI `Color` or AppKit
/// `NSColor`: this package has no UI framework dependency, so callers convert
/// to their platform's color type at the point of use, and MUST specify the
/// sRGB color space explicitly when doing so -- e.g.
/// `NSColor(srgbRed: color.red / 255, green: ..., blue: ..., alpha: 1)`.
/// On a wide-gamut Display P3 Mac, a color literal interpreted in the
/// display's native color space renders visibly different values than EPA
/// specified.
public struct AQIColor: Sendable, Equatable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Hex string, e.g. "#00E400" -- as published in the TAD.
    public var hex: String {
        let r = Int(red)
        let g = Int(green)
        let b = Int(blue)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Perceived brightness via the standard broadcast-luma weighting
    /// (ITU-R BT.601: 0.299R + 0.587G + 0.114B, weighted by how sensitive
    /// human vision is to each channel) -- true when this color reads as
    /// "light" against the conventional 128-of-255 midpoint. Used to
    /// choose readable black-or-white text over a background filled with
    /// this color (bluegull-aqi-mtm.19): plain colored text on a plain
    /// background -- the previous approach -- has poor contrast for the
    /// lighter categories (Good, Moderate, USG), which is what prompted
    /// this. Verified against AirNow's own AQI Legend panel, which uses
    /// exactly this pairing (black text on Good/Moderate/USG, white on
    /// Unhealthy/Very Unhealthy/Hazardous) for all 6 official colors.
    public var isLight: Bool {
        (red * 299 + green * 587 + blue * 114) / 1000 >= 128
    }
}
