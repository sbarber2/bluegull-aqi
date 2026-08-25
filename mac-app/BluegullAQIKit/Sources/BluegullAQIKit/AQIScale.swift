import Foundation

/// Maps an AQI value onto a 0...1 position along the category-color scale
/// bar shown on the widget faces (bluegull-aqi-e70.51). Deliberately
/// separate from `AQICategory.init(aqi:)` -- that answers "which category,"
/// this answers "where along a fixed-width bar," and the two aren't the
/// same question: the bar compresses the upper end of the scale (Very
/// Unhealthy/Hazardous cover 201...500+, a much wider AQI range than the
/// 50-point bands below them) so all six category colors stay visibly
/// present on a small, fixed-width bar instead of the top two bands being
/// squeezed to a sliver or the bar needing to be unrealistically wide.
///
/// The anchor points below match the design canvas this was approved from
/// (https://claude.ai/code/artifact/89fd3628-000e-4071-b65b-3a8eb37f2263):
/// AQI 0/50/100/150/200/300/500 map to fraction 0/0.15/0.30/0.45/0.60/
/// 0.85/1.0, moving smoothly between each pair. The first four bands (Good
/// through Unhealthy) are equal-width 50-point bands and land as equal
/// 15%-wide segments; Very Unhealthy (201...300) gets 25% width, and
/// Hazardous (301...500, plus anything beyond that AQICategory itself
/// treats as `.beyondAQI`) is compressed into the final 15%.
public enum AQIScale {
    /// (aqi, fraction) pairs this mapping moves smoothly between. Not
    /// `AQICategory`'s own category thresholds restated -- see this type's
    /// own doc comment for why the two deliberately differ.
    private static let scaleAnchors: [(aqi: Double, fraction: Double)] = [
        (0, 0), (50, 0.15), (100, 0.30), (150, 0.45), (200, 0.60), (300, 0.85), (500, 1.0),
    ]

    /// `aqi` is clamped to 0...500 first -- values above 500 (real,
    /// AirNow-supplied data, see `AQICategory.beyondAQI`'s own doc comment)
    /// all land at the same fraction 1.0, the same "off the end of the bar"
    /// treatment as an exact 500.
    public static func fraction(forAQI aqi: Int) -> Double {
        let value = Double(min(max(aqi, 0), 500))
        for index in 0..<(scaleAnchors.count - 1) {
            let lower = scaleAnchors[index]
            let upper = scaleAnchors[index + 1]
            if value >= lower.aqi, value <= upper.aqi {
                let t = (value - lower.aqi) / (upper.aqi - lower.aqi)
                return lower.fraction + t * (upper.fraction - lower.fraction)
            }
        }
        return 1.0
    }
}
