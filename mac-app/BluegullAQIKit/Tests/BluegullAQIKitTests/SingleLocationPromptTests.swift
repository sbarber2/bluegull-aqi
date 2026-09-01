import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.6's acceptance criteria, as a test rather than as an
/// intention: exactly ONE location permission prompt across a clean install
/// and first run, and it comes from the helper.
///
/// This is worth encoding mechanically because the failure is invisible in
/// development and permanent in the field. The system prompt is one shot --
/// CoreLocation refuses to re-prompt once answered, and the locationd record
/// cannot be cleared (tccutil fails -10814) -- so a second prompt reaching a
/// user cannot be taken back by a later fix. And nobody testing on a machine
/// that already granted location would ever see it.
///
/// Same shape as `ComplianceTests`: scan the source that actually ships,
/// with comments stripped so a doc comment discussing the rule doesn't trip
/// the rule.
final class SingleLocationPromptTests: XCTestCase {
    /// Every call that can put the system location dialog on screen.
    private static let promptingCalls = [
        "requestWhenInUseAuthorization",
        "requestAlwaysAuthorization",
        "requestTemporaryFullAccuracyAuthorization",
    ]

    /// The bundles that must never ask. The helper is deliberately absent:
    /// it is the one that does.
    private static let nonAskingTargets = [
        "BluegullAQI",        // the container app
        "BluegullAQIWidget",  // the widget extension
    ]

    func testOnlyTheHelperCanTriggerASystemLocationPrompt() throws {
        for target in Self.nonAskingTargets {
            let directory = Self.macAppDirectory().appendingPathComponent(target)
            let files = try Self.swiftFiles(under: directory)
            XCTAssertFalse(files.isEmpty, "Expected .swift files under \(directory.path)")

            for fileURL in files {
                let code = try Self.codeOnly(contentsOf: fileURL)
                for call in Self.promptingCalls {
                    XCTAssertFalse(
                        code.contains(call),
                        "\(target)/\(fileURL.lastPathComponent) calls \(call). Under bluegull-aqi-hib.6 " +
                        "the helper agent is the sole location owner -- a second asker means a second " +
                        "prompt, which cannot be undone once a user has seen it."
                    )
                }
            }
        }
    }

    /// The package is linked into the app AND the widget extension, so a
    /// prompting call here would reach both. This is why
    /// `LocationAuthorizationRequester` lives in the helper target instead.
    func testTheSharedPackageNeverAsksEither() throws {
        let sources = Self.macAppDirectory()
            .appendingPathComponent("BluegullAQIKit")
            .appendingPathComponent("Sources")
        for fileURL in try Self.swiftFiles(under: sources) {
            let code = try Self.codeOnly(contentsOf: fileURL)
            for call in Self.promptingCalls {
                XCTAssertFalse(
                    code.contains(call),
                    "\(fileURL.lastPathComponent) calls \(call) in shared code linked into every process."
                )
            }
        }
    }

    /// Belt to the source scan's braces, and the stronger of the two: the
    /// sandbox refuses location to a process without this entitlement
    /// whatever its code says. Removing it is what makes "the app never
    /// asks" structurally true rather than true by inspection.
    func testTheAppHasNoLocationEntitlement() throws {
        let entitlements = try Self.plist(at: Self.macAppDirectory()
            .appendingPathComponent("BluegullAQI/BluegullAQI.entitlements"))
        XCTAssertNil(
            entitlements["com.apple.security.personal-information.location"],
            "bluegull-aqi-hib.6: the app is not a location client any more; the helper is."
        )
    }

    func testTheWidgetHasNoLocationEntitlement() throws {
        let entitlements = try Self.plist(at: Self.macAppDirectory()
            .appendingPathComponent("BluegullAQIWidget/BluegullAQIWidget.entitlements"))
        XCTAssertNil(entitlements["com.apple.security.personal-information.location"])
    }

    /// The helper must keep BOTH, or the prompt it is supposed to show
    /// either can't happen (no entitlement) or shows with no explanation
    /// (no usage description). This is the positive half of the same rule.
    func testTheHelperIsTheOneBundleThatCanAsk() throws {
        let entitlements = try Self.plist(at: Self.macAppDirectory()
            .appendingPathComponent("BluegullAQIHelper/BluegullAQIHelper.entitlements"))
        XCTAssertEqual(entitlements["com.apple.security.personal-information.location"] as? Bool, true)

        let info = try Self.plist(at: Self.macAppDirectory()
            .appendingPathComponent("BluegullAQIHelper/Info.plist"))
        let usage = info["NSLocationWhenInUseUsageDescription"] as? String
        XCTAssertNotNil(usage, "the prompt quotes this string; without it macOS refuses to show one at all")
        XCTAssertFalse(usage?.isEmpty ?? true)
    }

    /// The prompt is attributed to the HELPER's display name, not the app's.
    /// The hib.10 probe's said "BlueGull AQI Location Probe", which is not a
    /// thing any user has heard of -- and under hib.6 this is the only name
    /// they ever see attached to the request.
    func testTheHelperPresentsItselfAsBlueGull() throws {
        let info = try Self.plist(at: Self.macAppDirectory()
            .appendingPathComponent("BluegullAQIHelper/Info.plist"))
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "BlueGull AQI")
    }

    // MARK: - Helpers (same shape as ComplianceTests')

    private static func macAppDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BluegullAQIKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BluegullAQIKit
            .deletingLastPathComponent()   // mac-app
    }

    private static func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    /// Strips `//` comments so a doc comment that names a forbidden call --
    /// this file's own siblings do, repeatedly -- doesn't fail the scan.
    private static func codeOnly(contentsOf url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(directory.path)")
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            files.append(fileURL)
        }
        return files
    }
}
