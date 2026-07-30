import XCTest

/// Hard constraint from two independent sources (bluegull-aqi-10h.17): the
/// AirNow Data Exchange Guidelines require data be "disseminated as
/// received" without alteration, and the AQI Technical Assistance Document
/// independently states it is "not valid to use shorter-term (e.g. hourly)
/// data to calculate an AQI value." So: this package must never convert a
/// pollutant concentration into an AQI, re-derive one, or interpolate
/// against a breakpoint table -- `AQICategory.init(aqi:)` only ever maps an
/// AQI value AirNow itself already returned.
///
/// This test scans `Sources/` for identifiers/terms that would only appear
/// if someone were implementing the TAD's breakpoint/interpolation
/// calculation (Table 5 / Equation 1) client-side -- e.g. trying to "fill
/// in" an AQI for a pollutant AirNow didn't supply one for. It exists so
/// that reintroduction is caught immediately, not just prevented by
/// intent/code review.
final class ComplianceTests: XCTestCase {
    /// Terms that should never appear in this package's source -- each one
    /// only makes sense as part of a client-side AQI calculation, which is
    /// exactly what bluegull-aqi-10h.17 forbids. Deliberately does NOT
    /// include the TAD's actual breakpoint numbers (e.g. "35.4"): plain
    /// numeric literals are too likely to collide with unrelated code and
    /// would make this test brittle rather than meaningful.
    private static let forbiddenTerms = [
        "breakpoint",
        "interpolat",
        "computeaqi",
        "deriveaqi",
        "calculateaqi",
        "aqiformula",
        "concentrationtoaqi",
    ]

    func testNoAQIDerivationLogicExistsInSources() throws {
        let sourcesDirectory = try Self.sourcesDirectory()
        let swiftFiles = try Self.swiftFiles(under: sourcesDirectory)
        XCTAssertFalse(swiftFiles.isEmpty, "Expected to find .swift files under \(sourcesDirectory.path)")

        for fileURL in swiftFiles {
            let code = try Self.codeOnly(contentsOf: fileURL).lowercased()
            for term in Self.forbiddenTerms {
                XCTAssertFalse(
                    code.contains(term),
                    "\(fileURL.lastPathComponent) contains '\(term)' outside a comment -- looks like " +
                    "client-side AQI derivation, which bluegull-aqi-10h.17 forbids. AQI values must " +
                    "come from AirNow unaltered; never computed from a concentration."
                )
            }
        }
    }

    /// Strips `//` and `///` comment lines before scanning -- this test is
    /// about forbidding actual derivation *code*, not prose that documents
    /// the constraint (which understandably needs to name the very things
    /// it forbids, e.g. "never interpolates").
    private static func codeOnly(contentsOf fileURL: URL) throws -> String {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Locates Sources/BluegullAQIKit relative to this test file's own path
    /// (`#filePath`), so the test works regardless of the machine or CI
    /// working directory it runs from.
    private static func sourcesDirectory() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/BluegullAQIKitTests/ComplianceTests.swift -> .../Tests/BluegullAQIKitTests
            .deletingLastPathComponent()  // -> .../Tests
            .deletingLastPathComponent()  // -> package root
            .appendingPathComponent("Sources")
            .appendingPathComponent("BluegullAQIKit")
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
