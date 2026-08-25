import SwiftUI

/// Brand colors and the branded background treatment shared by the menu
/// bar popover (`AQIPopoverView`) and the widget detail window
/// (`WidgetDetailView`) -- extends the widget faces' own branding
/// (bluegull-aqi-e70.51) to these two surfaces for visual consistency,
/// per Steve's own request (2026-08-25).
///
/// Duplicated from `BluegullAQIKit/Sources/BluegullAQIWidgetViews/
/// WidgetBrand.swift`, not shared via `BluegullAQIKit` or a cross-module
/// import of `BluegullAQIWidgetViews` -- same "each UI target
/// converts/defines at its own point of use" reasoning as
/// `AQIColor+SwiftUI.swift`'s own doc comment (this app target and the
/// widget views module are kept independent so neither pulls in the
/// other's UI-specific concerns just to reuse a few color constants).
/// Named `AppBrand`, not `WidgetBrand`, since it's no longer widget-only
/// once this applies to the popover/detail window too.
enum AppBrand {
    /// `ARROW_BLUE` (112, 181, 236) -- the app icon's own light background
    /// blue, from `mac-app/branding/gen-dmg-background.py`. The gradient's
    /// *lightest* stop.
    static let iconBlue = Color(.sRGB, red: 112 / 255, green: 181 / 255, blue: 236 / 255, opacity: 1)

    /// A blend between `iconBlue` and `navy`, used as the gradient's middle
    /// stop rather than letting the two brand colors blend on their own.
    static let midBlue = Color(.sRGB, red: 62 / 255, green: 127 / 255, blue: 190 / 255, opacity: 1)

    /// `NAVY` (20, 40, 70), also from `gen-dmg-background.py` -- this
    /// gradient's darkest stop and the fixed text color for content
    /// sitting over the lighter part of the gradient.
    static let navy = Color(.sRGB, red: 20 / 255, green: 40 / 255, blue: 70 / 255, opacity: 1)

    /// The branded background, `iconBlue` at top fading to `navy` at
    /// bottom. `midStopLocation` is deliberately small (a fast transition
    /// to navy) for these two views compared to the widget faces' own
    /// 0.30-0.48 -- unlike a fixed-size widget, the popover/detail
    /// window's content height varies a lot (empty state vs. a full
    /// pollutant list plus timestamps plus the attribution paragraph), and
    /// only the first row or two (location name, resolved place) ever need
    /// the lighter top; everything else should stay comfortably dark
    /// regardless of how tall the content grows.
    static func backgroundGradient(midStopLocation: Double = 0.12) -> LinearGradient {
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
