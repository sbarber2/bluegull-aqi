import SwiftUI
import BluegullAQIKit

extension AQIColor {
    /// `BluegullAQIKit` deliberately has no UI framework dependency (see
    /// `AQIColor`'s own doc comment), so this conversion lives here, in the
    /// app target, not the package. MUST specify the sRGB color space
    /// explicitly -- on a wide-gamut Display P3 Mac, `Color(red:green:blue:)`
    /// (without an explicit color space) renders these official EPA values
    /// visibly differently than specified.
    var swiftUIColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
