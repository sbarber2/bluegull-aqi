import XCTest
import SwiftUI
import AppKit
import CoreGraphics

/// Hand-rolled golden-image comparison (bluegull-aqi-mtm.11) -- the issue
/// named `pointfreeco/swift-snapshot-testing` as an alternative, but this
/// project has no third-party dependencies anywhere (SPM or otherwise) and
/// the comparison needed here is simple enough not to justify adding the
/// first one just for this.
///
/// Set `RECORD_SNAPSHOTS=1` to (re)write golden files instead of comparing
/// against them, e.g.:
/// `RECORD_SNAPSHOTS=1 swift test --filter BluegullAQIWidgetSnapshotTests`
///
/// Compares decoded pixels with a small tolerance, NOT raw PNG bytes --
/// exact-byte comparison was the first implementation, and it was
/// genuinely flaky: `small-no-data` failed 100% of the time when the full
/// package test suite ran (but never when run alone), off by exactly 2
/// bytes, every time. Whatever earlier test happens to run first in the
/// same process measurably changes how AppKit/CoreText rasterizes the
/// SF Symbol in `noDataView` -- a real, reproducible environment quirk, not
/// a mistake in this harness. Per-channel tolerance plus an allowed
/// mismatched-pixel fraction is the same approach established
/// snapshot-testing libraries use for exactly this reason (e.g.
/// swift-snapshot-testing's `precision` parameter) -- not a workaround
/// invented just to paper over this one flake.
@MainActor
enum GoldenImageAssertion {
    private static let perChannelTolerance: UInt8 = 8
    private static let maxMismatchFraction = 0.005

    static func assert(
        _ view: some View,
        named name: String,
        size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2

        guard let candidateImage = renderer.cgImage else {
            XCTFail("Failed to render \(name)", file: file, line: line)
            return
        }

        let goldenURL = snapshotsDirectory.appendingPathComponent("\(name).png")

        if ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" {
            guard let pngData = pngData(for: candidateImage) else {
                XCTFail("Failed to encode \(name) as PNG", file: file, line: line)
                return
            }
            try? FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            try? pngData.write(to: goldenURL)
            XCTFail("Recorded new golden image for \(name) -- re-run without RECORD_SNAPSHOTS=1 to verify it.", file: file, line: line)
            return
        }

        guard let goldenData = try? Data(contentsOf: goldenURL),
              let goldenImage = NSBitmapImageRep(data: goldenData)?.cgImage else {
            XCTFail("No golden image for \(name) at \(goldenURL.path) -- run with RECORD_SNAPSHOTS=1 first.", file: file, line: line)
            return
        }

        guard candidateImage.width == goldenImage.width, candidateImage.height == goldenImage.height,
              let candidateBuffer = pixelBuffer(from: candidateImage),
              let goldenBuffer = pixelBuffer(from: goldenImage) else {
            XCTFail(
                "\(name) size changed: \(candidateImage.width)x\(candidateImage.height) vs golden \(goldenImage.width)x\(goldenImage.height)",
                file: file, line: line
            )
            return
        }

        let mismatchFraction = fractionDiffering(candidateBuffer, goldenBuffer, tolerance: perChannelTolerance)
        XCTAssertLessThanOrEqual(
            mismatchFraction, maxMismatchFraction,
            "\(name) differs from its golden image in \(String(format: "%.3f", mismatchFraction * 100))% "
                + "of pixels (allowed \(maxMismatchFraction * 100)%) at \(goldenURL.path)",
            file: file, line: line
        )
    }

    private static func pngData(for image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    /// Redraws into a fixed 8-bit-per-channel RGBA buffer regardless of the
    /// source image's own pixel format, so a candidate render and a golden
    /// PNG decoded off disk are always compared apples-to-apples.
    private static func pixelBuffer(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func fractionDiffering(_ a: [UInt8], _ b: [UInt8], tolerance: UInt8) -> Double {
        guard a.count == b.count, a.count > 0 else { return 1.0 }
        let pixelCount = a.count / 4
        var mismatches = 0
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            var pixelDiffers = false
            for channel in 0..<4 {
                if abs(Int(a[base + channel]) - Int(b[base + channel])) > Int(tolerance) {
                    pixelDiffers = true
                    break
                }
            }
            if pixelDiffers { mismatches += 1 }
        }
        return Double(mismatches) / Double(pixelCount)
    }

    private static let snapshotsDirectory = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__", isDirectory: true)
}
