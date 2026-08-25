import SwiftUI
import WidgetKit
import BluegullAQIKit

/// Brand colors and the branded background/scale-bar treatment for the
/// widget faces (bluegull-aqi-e70.51, design canvas
/// https://claude.ai/code/artifact/89fd3628-000e-4071-b65b-3a8eb37f2263).
/// Widget-only for now -- not applied to the menu bar popover.
///
/// The two named colors are the app icon's own colors, duplicated here from
/// `mac-app/branding/gen-dmg-background.py`'s `ARROW_BLUE`/`NAVY` constants
/// -- same "each target converts at its own point of use" reasoning as
/// `AQIColor+SwiftUI.swift` right next to this file (that Python script is
/// a separate, unrelated build-time toolchain with no way to share a Swift
/// source of truth). MUST specify the sRGB color space explicitly, same
/// gotcha as that file: on a wide-gamut Display P3 Mac, `Color(red:green:
/// blue:)` without an explicit color space renders these visibly
/// differently than the source PNG/generator script intended.
enum WidgetBrand {
    /// `ARROW_BLUE` (112, 181, 236) -- the app icon's own light background
    /// blue. The gradient's *lightest* stop.
    static let iconBlue = Color(.sRGB, red: 112 / 255, green: 181 / 255, blue: 236 / 255, opacity: 1)

    /// A blend between `iconBlue` and `navy`, used as the gradient's middle
    /// stop rather than letting the two brand colors blend on their own --
    /// a plain two-stop gradient between them read muddier in the design
    /// canvas than a deliberate three-stop one.
    static let midBlue = Color(.sRGB, red: 62 / 255, green: 127 / 255, blue: 190 / 255, opacity: 1)

    /// `NAVY` (20, 40, 70) -- the DMG background's title-text color, also
    /// used as this gradient's darkest stop and as the fixed text color for
    /// content sitting over the lighter part of the gradient (location
    /// name, resolved place name, Small's stale badge).
    static let navy = Color(.sRGB, red: 20 / 255, green: 40 / 255, blue: 70 / 255, opacity: 1)

    /// The branded background, `iconBlue` at top fading to `navy` at
    /// bottom. `midStopLocation` differs by widget family (see call
    /// sites): Large's pollutant list needs the lower portion solidly dark
    /// sooner than Small/Medium's shorter, less content-heavy layouts do.
    static func backgroundGradient(midStopLocation: Double) -> LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: iconBlue, location: 0),
                .init(color: midBlue, location: midStopLocation),
                .init(color: navy, location: 1),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The category-color scale bar with a marker at the current reading's
/// position (bluegull-aqi-e70.51) -- replaces the small `Circle()` category
/// dot every layout used before this. Six hard-stop segments, the real EPA
/// category colors (`AQICategory.color`), at the fractions
/// `AQIScale.fraction(forAQI:)` defines -- see that type's own doc comment
/// for why the segments aren't proportional to AQI point-range above 300.
struct AQIScaleBar: View {
    let aqi: Int
    var width: CGFloat
    var height: CGFloat = 8
    var markerDiameter: CGFloat = 12

    // Fixed EPA category colors, in scale order -- see AQICategory.color's
    // own doc comment for the source (TAD Tables 1/2). Not computed from
    // AQICategory itself since this needs all six regardless of which one
    // the current reading falls in.
    private static let segmentColors: [Color] = [
        AQIColor(red: 0, green: 228, blue: 0).swiftUIColor,      // Good
        AQIColor(red: 255, green: 255, blue: 0).swiftUIColor,    // Moderate
        AQIColor(red: 255, green: 126, blue: 0).swiftUIColor,    // USG
        AQIColor(red: 255, green: 0, blue: 0).swiftUIColor,      // Unhealthy
        AQIColor(red: 143, green: 63, blue: 151).swiftUIColor,   // Very Unhealthy
        AQIColor(red: 126, green: 0, blue: 35).swiftUIColor,     // Hazardous
    ]

    // The same fraction boundaries AQIScale.fraction(forAQI:) moves
    // between (0, 0.15, 0.30, 0.45, 0.60, 0.85, 1.0), expressed as
    // per-segment (start, end) pairs for the gradient stops below.
    private static let segmentBounds: [(start: Double, end: Double)] = [
        (0, 0.15), (0.15, 0.30), (0.30, 0.45), (0.45, 0.60), (0.60, 0.85), (0.85, 1.0),
    ]

    private var track: LinearGradient {
        var stops: [Gradient.Stop] = []
        for (index, bounds) in Self.segmentBounds.enumerated() {
            let color = Self.segmentColors[index]
            stops.append(.init(color: color, location: bounds.start))
            stops.append(.init(color: color, location: bounds.end))
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(track)
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: height / 2)
                        .strokeBorder(WidgetBrand.navy.opacity(0.25), lineWidth: 1)
                )
            Circle()
                .fill(.white)
                .frame(width: markerDiameter, height: markerDiameter)
                .overlay(Circle().strokeBorder(WidgetBrand.navy, lineWidth: 2))
                // Center the marker at `fraction * width` along the track,
                // clamped so it never draws past either end at the extremes
                // (fraction 0 or 1) -- half its own diameter in from the
                // track's edge, not centered exactly on it, so it doesn't
                // spill outside the rounded pill's own bounds.
                .offset(x: min(max(AQIScale.fraction(forAQI: aqi) * width, markerDiameter / 2), width - markerDiameter / 2) - markerDiameter / 2)
        }
        .frame(width: width, height: max(height, markerDiameter), alignment: .center)
    }
}
