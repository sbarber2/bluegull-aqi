// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BluegullAQIKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BluegullAQIKit",
            targets: ["BluegullAQIKit"]
        ),
        .library(
            name: "BluegullAQIWidgetViews",
            targets: ["BluegullAQIWidgetViews"]
        ),
        .executable(
            name: "WidgetRenderHarness",
            targets: ["WidgetRenderHarness"]
        ),
    ],
    targets: [
        .target(
            name: "BluegullAQIKit"
        ),
        // The widget's own View code, split out from the BluegullAQIWidget
        // app-extension target (bluegull-aqi-mtm.10) -- an app-extension
        // build product can't be linked by a separate test target (see
        // WidgetTimelineComputer's own doc comment for the confirmed build
        // error), so this is a normal library, importable by both the
        // extension itself and by test/harness targets. Unlike
        // BluegullAQIKit, this target DOES depend on SwiftUI/WidgetKit --
        // it's specifically the widget's presentation layer.
        .target(
            name: "BluegullAQIWidgetViews",
            dependencies: ["BluegullAQIKit"]
        ),
        // Renders fixture widget entries to PNGs from the command line, no
        // widget host or GUI needed (bluegull-aqi-mtm.10) -- run with
        // `swift run WidgetRenderHarness <output-directory>`.
        .executableTarget(
            name: "WidgetRenderHarness",
            dependencies: ["BluegullAQIWidgetViews"]
        ),
        .testTarget(
            name: "BluegullAQIKitTests",
            dependencies: ["BluegullAQIKit"]
        ),
        .testTarget(
            name: "BluegullAQIWidgetViewsTests",
            dependencies: ["BluegullAQIWidgetViews"]
        ),
        // Split from BluegullAQIWidgetViewsTests (bluegull-aqi-67l): this
        // target does pixel-level golden-image comparison
        // (GoldenImageAssertion), which is sensitive to font/SF Symbol
        // rasterization differences between the machine that recorded
        // __Snapshots__/ and whatever machine runs the test -- confirmed
        // via CI failing this way on every run since the workflow was
        // added, never a real visual regression. Kept out of `swift test`'s
        // default target set (test-swift skips it; `make test-snapshots`
        // runs it explicitly) so that noise doesn't block the functional
        // suite, matching the existing test-ui precedent (continue-on-error
        // in CI) for the same "different environment renders differently"
        // reason.
        .testTarget(
            name: "BluegullAQIWidgetSnapshotTests",
            dependencies: ["BluegullAQIWidgetViews"],
            // The golden PNGs (bluegull-aqi-mtm.11) are test fixtures read
            // directly off disk by file path, not bundled resources.
            exclude: ["__Snapshots__"]
        ),
    ]
)
