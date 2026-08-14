import AppKit
import SwiftUI
import WidgetKit
import BluegullAQIKit
import BluegullAQIWidgetViews

/// Renders fixture small/medium/large widget entries to PNGs on disk --
/// `swift run WidgetRenderHarness [output-directory]` (defaults to the
/// current directory). No widget host or GUI interaction needed
/// (bluegull-aqi-mtm.10): a WidgetKit view is just a SwiftUI view, so
/// ImageRenderer (macOS 13+) can render it headlessly. For direct visual
/// inspection by a human or an image-capable agent, and as a fixture
/// source for `mtm.11`'s golden-image regression tests -- NOT itself a
/// pixel-exact device rendering (see `approximateSizes` below).
///
/// A `@main` struct, not a plain `main.swift` script, because
/// `ImageRenderer` is `@MainActor`-isolated and top-level code in a
/// script-style `main.swift` runs in a nonisolated context in this SDK
/// (confirmed via a real build error) -- `@MainActor static func main()`
/// gives the isolation `ImageRenderer` actually needs.
@main
struct WidgetRenderHarness {
    // Approximate macOS widget face dimensions (points) -- close enough
    // for visual inspection of layout/overflow, not claimed pixel-exact
    // against any particular macOS version's actual widget host sizing.
    // Pixel-exact golden images are mtm.11's separate, dedicated scope.
    static let approximateSizes: [WidgetFamily: CGSize] = [
        .systemSmall: CGSize(width: 158, height: 158),
        .systemMedium: CGSize(width: 338, height: 158),
        .systemLarge: CGSize(width: 338, height: 358),
    ]

    @MainActor
    static func main() {
        let outputDirectory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let entryWithData = BluegullAQIWidgetEntry(date: Date(), reading: sampleReading, configuredLocation: sampleLocation)
        let entryNoData = BluegullAQIWidgetEntry(date: Date(), reading: nil)
        // bluegull-aqi-dc2.6: reading present but AQIFreshness.stale --
        // distinct from entryNoData above (no surviving reading at all).
        let entryAged = BluegullAQIWidgetEntry(date: Date(), reading: sampleReading, configuredLocation: sampleLocation, freshness: .stale)

        let fixtures: [(name: String, entry: BluegullAQIWidgetEntry, family: WidgetFamily)] = [
            ("small", entryWithData, .systemSmall),
            ("medium", entryWithData, .systemMedium),
            ("large", entryWithData, .systemLarge),
            ("small-no-data", entryNoData, .systemSmall),
            ("medium-no-data", entryNoData, .systemMedium),
            ("large-no-data", entryNoData, .systemLarge),
            ("small-aged-reading", entryAged, .systemSmall),
            ("medium-aged-reading", entryAged, .systemMedium),
            ("large-aged-reading", entryAged, .systemLarge),
        ]

        var failureCount = 0

        for fixture in fixtures {
            let size = approximateSizes[fixture.family] ?? CGSize(width: 158, height: 158)
            let view = BluegullAQIWidgetView(entry: fixture.entry, familyOverride: fixture.family)
                .frame(width: size.width, height: size.height)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2

            guard let nsImage = renderer.nsImage,
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                FileHandle.standardError.write(Data("Failed to render \(fixture.name)\n".utf8))
                failureCount += 1
                continue
            }

            let fileURL = outputURL.appendingPathComponent("\(fixture.name).png")
            do {
                try pngData.write(to: fileURL)
                print("Wrote \(fileURL.path)")
            } catch {
                FileHandle.standardError.write(Data("Failed to write \(fileURL.path): \(error)\n".utf8))
                failureCount += 1
            }
        }

        if failureCount > 0 {
            exit(1)
        }
    }

    private static let sampleLocation = Location(latitude: 37.7749, longitude: -122.4194)

    private static let sampleReading = AQIReading(
        location: sampleLocation,
        pollutants: [
            samplePollutant(parameterName: "PM2.5", nowcastAQI: 78, aqiCategoryName: "Moderate"),
            samplePollutant(parameterName: "OZONE", nowcastAQI: 42, aqiCategoryName: "Good"),
            samplePollutant(parameterName: "PM10", nowcastAQI: 15, aqiCategoryName: "Good"),
        ]
    )

    private static func samplePollutant(parameterName: String, nowcastAQI: Int, aqiCategoryName: String) -> PollutantReading {
        PollutantReading(
            dateObserved: "2026-07-30",
            hourObserved: "14",
            localTimeZone: "PDT",
            reportingAreaName: "San Francisco",
            siteID: "060750005",
            siteName: "San Francisco",
            parameterName: parameterName,
            nowcastAQI: nowcastAQI,
            aqiCategoryName: aqiCategoryName,
            reportingAgency: "Bay Area Air District",
            lookupBehavior: "Closest Reading By Pollutant",
            consideredMonitors: "All",
            lookupBoundary: "50 Miles"
        )
    }
}
