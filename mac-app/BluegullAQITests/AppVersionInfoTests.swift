import XCTest
@testable import BluegullAQI

final class AppVersionInfoTests: XCTestCase {
    func testFormatsVersionBuildAndCommit() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: "d5bd66a", releaseTag: "v0.1.0"),
            "v0.1.0 (171) · d5bd66a"
        )
    }

    func testOmitsCommitWhenNil() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: nil, releaseTag: "v0.1.0"),
            "v0.1.0 (171)"
        )
    }

    func testOmitsCommitWhenEmpty() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: "", releaseTag: "v0.1.0"),
            "v0.1.0 (171)"
        )
    }

    // A raw Xcode build that bypassed the Makefile's command-line override
    // leaves the literal, unexpanded build-setting reference in Info.plist
    // -- must not leak into the UI as-is.
    func testOmitsCommitWhenUnexpandedBuildSettingReference() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: "0.1.0", buildNumber: "171", gitCommitSHA: "$(GIT_COMMIT_SHA)", releaseTag: "v0.1.0"),
            "v0.1.0 (171)"
        )
    }

    func testFallsBackToPlaceholdersWhenMissing() {
        XCTAssertEqual(
            AppVersionInfo.displayString(shortVersion: nil, buildNumber: nil, gitCommitSHA: nil, releaseTag: "v0.1.0"),
            "v? (?)"
        )
    }
}

/// bluegull-aqi-hib.16. The marker exists so a dev build says so without
/// putting a non-numeric string in `CFBundleShortVersionString` — App Store
/// Connect rejects those, and 8ef.16 plans App Store distribution.
///
/// It is derived from a git tag rather than typed, so what these cover is
/// the mapping from "what the Makefile found" to "what the user reads".
final class DevelopmentBuildMarkerTests: XCTestCase {
    private func string(releaseTag: String?) -> String {
        AppVersionInfo.displayString(
            shortVersion: "0.3.0", buildNumber: "256", gitCommitSHA: "abc1234", releaseTag: releaseTag
        )
    }

    func testATaggedBuildCarriesNoMarker() {
        XCTAssertEqual(string(releaseTag: "v0.3.0"), "v0.3.0 (256) · abc1234")
    }

    /// The Makefile leaves this empty for any commit without an exact tag,
    /// AND blanks it when the working tree is dirty — `git describe
    /// --exact-match` will happily describe a tagged commit with
    /// uncommitted changes on top, and that is not a release build.
    func testAnUntaggedBuildIsMarked() {
        XCTAssertEqual(string(releaseTag: ""), "v0.3.0-dev (256) · abc1234")
        XCTAssertEqual(string(releaseTag: nil), "v0.3.0-dev (256) · abc1234")
    }

    /// A raw Xcode build bypasses the Makefile entirely, leaving the literal
    /// build-setting reference. It must read as "no tag" — not as a release
    /// tagged `$(GIT_RELEASE_TAG)`, which would silently un-mark exactly the
    /// builds most likely to be mistaken for releases.
    func testAnUnexpandedReferenceCountsAsUntagged() {
        XCTAssertEqual(string(releaseTag: "$(GIT_RELEASE_TAG)"), "v0.3.0-dev (256) · abc1234")
        XCTAssertFalse(AppVersionInfo.isRelease(releaseTag: "$(GIT_RELEASE_TAG)"))
    }

    /// The marker never reaches the numeric version itself. This is the
    /// whole reason the feature is shaped this way rather than as a
    /// hand-edited "0.3.0dev".
    func testTheMarkerIsDisplayOnlyAndNeverTouchesTheBundleVersion() {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let numeric = shortVersion?.allSatisfy { $0.isNumber || $0 == "." } ?? false

        XCTAssertTrue(
            numeric,
            "CFBundleShortVersionString must stay strictly numeric; got \(shortVersion ?? "nil")"
        )
    }

    /// `isRelease` is the one predicate two call sites depend on — the
    /// display string and whether the popover shows its footer at all — so
    /// they must never disagree.
    func testTheMarkerAndTheFooterAgreeOnWhatARelaseIs() {
        for tag in ["v0.3.0", "", nil, "$(GIT_RELEASE_TAG)"] as [String?] {
            let marked = string(releaseTag: tag).contains("-dev")
            XCTAssertEqual(marked, !AppVersionInfo.isRelease(releaseTag: tag), "disagreement for tag \(tag ?? "nil")")
        }
    }
}
