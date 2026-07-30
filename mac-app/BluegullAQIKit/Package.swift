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
    ]
)
