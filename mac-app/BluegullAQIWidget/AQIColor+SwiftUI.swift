import SwiftUI
import BluegullAQIKit

extension AQIColor {
    /// Same conversion as the container app's identical file
    /// (`BluegullAQI/AQIColor+SwiftUI.swift`) -- duplicated, not shared via
    /// `BluegullAQIKit`, because the package deliberately has no UI
    /// framework dependency (see `AQIColor`'s own doc comment); each UI
    /// target converts at its own point of use. MUST specify the sRGB color
    /// space explicitly -- on a wide-gamut Display P3 Mac, `Color(red:green:blue:)`
    /// (without an explicit color space) renders these official EPA values
    /// visibly differently than specified.
    var swiftUIColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
