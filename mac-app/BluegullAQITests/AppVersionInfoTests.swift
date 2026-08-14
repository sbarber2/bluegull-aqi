import XCTest
@testable import BluegullAQI

final class AppVersionInfoTests: XCTestCase {
    func testFormatsVersionBuildAndCommit() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: "d5bd66a"),
            "v0.1.0 (171) · d5bd66a"
        )
    }

    func testOmitsCommitWhenNil() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: nil),
            "v0.1.0 (171)"
        )
    }

    func testOmitsCommitWhenEmpty() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: ""),
            "v0.1.0 (171)"
        )
    }

    // A raw Xcode build that bypassed the Makefile's command-line override
    // leaves the literal, unexpanded build-setting reference in Info.plist
    // -- must not leak into the UI as-is.
    func testOmitsCommitWhenUnexpandedBuildSettingReference() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: "$(GIT_COMMIT_SHA)"),
            "v0.1.0 (171)"
        )
    }

    func testFallsBackToPlaceholdersWhenMissing() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: nil, buildNumber: nil, gitCommitSHA: nil),
            "v? (?)"
        )
    }
}
