import SwiftUI
import BluegullAQIKit

extension AQIColor {
    /// Same conversion as the container app's identical file
    /// (`BluegullAQI/AQIColor+SwiftUI.swift`) -- duplicated, not shared via
    /// `BluegullAQIKit`, because that package deliberately has no UI
    /// framework dependency (see `AQIColor`'s own doc comment); each UI
    /// target converts at its own point of use. This copy lives here
    /// (not in the `BluegullAQIWidget` app-extension target) because it's
    /// used by the widget's own View code, which itself lives here for the
    /// same reason `WidgetTimelineComputer` does (bluegull-aqi-mtm.10): an
    /// app-extension build product can't be linked by a separate test/
    /// harness target. MUST specify the sRGB color space explicitly -- on a
    /// wide-gamut Display P3 Mac, `Color(red:green:blue:)` (without an
    /// explicit color space) renders these official EPA values visibly
    /// differently than specified.
    var swiftUIColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }

    /// Black or white, whichever is readable as text over this color used
    /// as a background fill -- see `AQIColor.isLight`'s own doc comment
    /// (bluegull-aqi-mtm.19).
    var contrastingTextColor: Color {
        isLight ? .black : .white
    }
}
