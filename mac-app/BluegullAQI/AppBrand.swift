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

    /// `SettingsView`'s own background (bluegull-aqi-as9,
    /// Steve, 2026-08-27) -- a flat color, not `backgroundGradient()`,
    /// deliberately scoped to Settings ALONE; the popover and detail
    /// window keep the gradient. Reasoning, Steve's own words: "It's been
    /// way too fiddly to deal with making the foreground (text and icons)
    /// contrast with gradient background... getting user complaints
    /// about the contrast." Settings has far more small controls (fields,
    /// toggles, buttons, captions) than the other two surfaces, each one
    /// needing its own top-vs-bottom-of-gradient color judgment call --
    /// that per-element navy-or-white decision was the actual source of
    /// the fiddliness and the complaints, not the brand colors
    /// themselves. A flat background removes the judgment call entirely:
    /// every foreground element in Settings is just `.white` now, no
    /// exceptions. `navy`, not `midBlue` -- `midBlue` is already this
    /// panel's own CONTROL-surface color (`brandFieldStyle`, button
    /// tint), so the page background needs to read as a distinct,
    /// darker surface behind those controls, not blend into them.
    static let settingsBackground = navy
}

extension View {
    /// Branded text-field/secure-field chrome (bluegull-aqi-a22) -- white
    /// text on a filled `AppBrand.midBlue` box, not `.textFieldStyle(.roundedBorder)`'s
    /// stark white-on-white box. Confirmed live, Steve, 2026-08-25: the
    /// system style's plain white background was "very jarring" against
    /// AppBrand's dark gradient (this was true even without forcing
    /// `.preferredColorScheme(.dark)` -- `.roundedBorder` renders a light
    /// box regardless of the surrounding content's own colors). `midBlue`,
    /// not `navy` -- Steve asked for the same color as this panel's own
    /// button chrome, which `.tint(AppBrand.navy)` (SettingsView's
    /// DataSourceModeToggle) leaves the *lighter* of the two brand blues
    /// as the one distinct enough to read as its own "control" surface
    /// against navy's own darker background.
    func brandFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppBrand.midBlue, in: RoundedRectangle(cornerRadius: 6))
    }
}
