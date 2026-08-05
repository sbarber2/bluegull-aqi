import XCTest
@testable import BluegullAQIKit

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

    /// Phrases that imply an instantaneous spot measurement, which AirNow's
    /// NowCast AQI values are not (bluegull-aqi-10h.18) -- the exact
    /// examples the issue itself calls out as unsafe. Checked lowercase, so
    /// this also catches capitalized UI copy.
    private static let forbiddenSpotReadingPhrases = [
        "right now",
        "current reading",
        "instant reading",
        "instantaneous reading",
    ]

    func testNoSpotReadingPhrasingExistsInSources() throws {
        let sourcesDirectory = try Self.sourcesDirectory()
        let swiftFiles = try Self.swiftFiles(under: sourcesDirectory)

        for fileURL in swiftFiles {
            let code = try Self.codeOnly(contentsOf: fileURL).lowercased()
            for phrase in Self.forbiddenSpotReadingPhrases {
                XCTAssertFalse(
                    code.contains(phrase),
                    "\(fileURL.lastPathComponent) contains '\(phrase)' outside a comment -- implies an " +
                    "instantaneous spot measurement, which bluegull-aqi-10h.18 forbids: AirNow's values " +
                    "are NowCast AQI, a variable-window weighted average, not a spot reading. Use " +
                    "NowCastCopy.headline (\"Current Air Quality\") instead."
                )
            }
        }
    }

    /// bluegull-aqi-10h.20: the AQI Technical Assistance Document FAQ says
    /// EPA's own focus group testing found the public understands and
    /// prefers "particle pollution" over "particulate matter." Use
    /// `PollutantCopy.spelledOutName(forParameterName:)` instead of
    /// inventing wording -- "PM2.5"/"PM10" themselves remain fine as
    /// compact labels, this only forbids the spelled-out "particulate
    /// matter" phrase.
    func testNoParticulateMatterPhrasingExistsInSources() throws {
        let sourcesDirectory = try Self.sourcesDirectory()
        let swiftFiles = try Self.swiftFiles(under: sourcesDirectory)

        for fileURL in swiftFiles {
            let code = try Self.codeOnly(contentsOf: fileURL).lowercased()
            XCTAssertFalse(
                code.contains("particulate matter"),
                "\(fileURL.lastPathComponent) contains 'particulate matter' outside a comment -- " +
                "bluegull-aqi-10h.20: EPA's own research found the public prefers 'particle pollution.' " +
                "Use PollutantCopy.spelledOutName(forParameterName:) instead."
            )
        }
    }

    /// bluegull-aqi-10h.13, revised by bluegull-aqi-mtm.25. This test used
    /// to assert that `kSecAttrAccessGroup` appeared *nowhere*, because only
    /// the container app needed the AirNow key. That stopped being true when
    /// the widget extension started performing its own fetches
    /// (bluegull-aqi-mtm.24), so the guard is inverted rather than deleted:
    /// a shared access group is now expected, but only the *one* known
    /// group. Catches a second, broader, or typo'd group being introduced.
    func testKeychainAccessGroupIsOnlyTheOneExpectedSharedGroup() throws {
        XCTAssertEqual(
            KeychainAccessGroup.shared,
            "G5DWPBWHQ5.solutions.bluegull.aqi",
            "The shared Keychain access group changed. It must stay in sync with the " +
            "keychain-access-groups entitlement in mac-app/project.yml -- if they diverge, " +
            "Keychain reads fail at runtime in whichever target is wrong."
        )

        let sourcesDirectory = try Self.sourcesDirectory()
        for fileURL in try Self.swiftFiles(under: sourcesDirectory) {
            let code = try Self.codeOnly(contentsOf: fileURL)
            guard code.lowercased().contains("ksecattraccessgroup") else { continue }
            XCTAssertTrue(
                code.contains("KeychainAccessGroup.shared"),
                "\(fileURL.lastPathComponent) sets kSecAttrAccessGroup to something other than " +
                "KeychainAccessGroup.shared. bluegull-aqi-mtm.25 permits exactly one shared group " +
                "(container app + widget extension, both of which fetch in Direct mode). Widening " +
                "that, or adding a second group, needs the same deliberate review this replaced."
            )
        }
    }

    /// CLAUDE.md's secrets rule names this as the likeliest leak in the
    /// project: AirNow takes its API key as a **URL query parameter**, so
    /// logging a request URL writes a live credential to the system log,
    /// and it looks exactly like ordinary debug logging. As of
    /// bluegull-aqi-mtm.25 the widget extension holds that key too, so the
    /// exposure exists in two processes rather than one.
    ///
    /// Deliberately conservative: it flags any logging call whose argument
    /// mentions a url/request/endpoint on the networking path, rather than
    /// trying to decide which ones are actually interpolating a key.
    func testNoRequestURLLogging() throws {
        let loggingCalls = ["print(", "nslog(", "os_log(", "logger.", "debugprint("]
        let urlish = ["url", "request", "endpoint", "components"]

        let sourcesDirectory = try Self.sourcesDirectory()
        for fileURL in try Self.swiftFiles(under: sourcesDirectory) {
            let code = try Self.codeOnly(contentsOf: fileURL)
            for rawLine in code.split(separator: "\n") {
                let line = rawLine.lowercased()
                guard loggingCalls.contains(where: line.contains) else { continue }
                guard urlish.contains(where: line.contains) else { continue }
                XCTFail(
                    "\(fileURL.lastPathComponent) appears to log a URL/request: \(rawLine.trimmingCharacters(in: .whitespaces))\n" +
                    "AirNow passes its API key as a URL query parameter, so this can write a live " +
                    "credential into the system log (CLAUDE.md, Secrets -- hard rule). Redact the " +
                    "URL before logging, or log a non-URL identifier instead."
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
