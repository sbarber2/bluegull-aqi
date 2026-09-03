import Foundation

/// Human-readable "which build is this" string (bluegull-aqi-fw4.9) --
/// surfaced at the bottom of `SettingsView`, and in the popover footer for
/// dev builds only (bluegull-aqi-hib.16) -- so a tester can read off
/// exactly what they're running instead of every ad-hoc build looking like
/// an indistinguishable "1.0".
///
/// `MARKETING_VERSION`/`CFBundleShortVersionString` is hand-bumped in
/// project.yml at real milestones. `CURRENT_PROJECT_VERSION`/
/// `CFBundleVersion`, `GitCommitSHA` and `GitReleaseTag` are all stamped in
/// at build time from git state (see the Makefile's
/// `XCODEBUILD_VERSION_OVERRIDES`), not maintained by hand -- so this reads
/// whatever actually got baked into the bundle, not a value this type
/// computes itself.
enum AppVersionInfo {
    static var current: String {
        displayString(
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            gitCommitSHA: Bundle.main.infoDictionary?["GitCommitSHA"] as? String,
            releaseTag: Bundle.main.infoDictionary?["GitReleaseTag"] as? String
        )
    }

    /// True unless this build came from a tagged, clean commit
    /// (bluegull-aqi-hib.16). Drives whether the popover shows its version
    /// footer at all -- release users see nothing, so this costs them no
    /// clutter, while a dev build is obvious from the surface Steve
    /// actually looks at rather than only from Settings.
    static var isDevelopmentBuild: Bool {
        !isRelease(releaseTag: Bundle.main.infoDictionary?["GitReleaseTag"] as? String)
    }

    /// A build is a release exactly when the Makefile found an exact tag on
    /// a clean tree. Everything else -- no tag, a dirty tree, a raw Xcode
    /// build that bypassed the Makefile entirely -- is a dev build.
    ///
    /// Deliberately derived rather than declared. A hand-typed "dev" suffix
    /// has to be hand-removed at release, and one day it will not be: that
    /// is the fw4.9 failure mode, where three ad-hoc DMGs all shipped
    /// reading "1.0" because a value nobody remembered to bump was baked
    /// in. This marker removes itself, because tagging IS the release step.
    static func isRelease(releaseTag: String?) -> Bool {
        guard let releaseTag, !releaseTag.isEmpty else { return false }
        // The literal unexpanded reference a raw Xcode build can leave
        // behind -- same guard as `gitCommitSHA` below, and here it must
        // read as "no tag" rather than as a tag named "$(GIT_RELEASE_TAG)".
        return !releaseTag.hasPrefix("$(")
    }

    /// `releaseTag` has no default on purpose: every caller should be
    /// explicit about which kind of build it is describing, because
    /// defaulting it either way silently mislabels something.
    static func displayString(
        shortVersion: String?,
        buildNumber: String?,
        gitCommitSHA: String?,
        releaseTag: String?
    ) -> String {
        let version = (shortVersion?.isEmpty == false) ? shortVersion! : "?"
        let build = (buildNumber?.isEmpty == false) ? buildNumber! : "?"
        // "-dev" on the DISPLAY string only. CFBundleShortVersionString
        // itself stays strictly numeric: Apple documents it as three
        // period-separated integers, and App Store Connect rejects anything
        // else -- which matters because bluegull-aqi-8ef.16 plans App Store
        // distribution by 1.0.
        let marker = isRelease(releaseTag: releaseTag) ? "" : "-dev"
        var text = "v\(version)\(marker) (\(build))"

        // Guards against the literal unexpanded "$(GIT_COMMIT_SHA)" that
        // shows up in a raw Xcode build that bypassed the Makefile's
        // command-line override -- see project.yml's own GIT_COMMIT_SHA
        // default and comment.
        if let gitCommitSHA, !gitCommitSHA.isEmpty, !gitCommitSHA.hasPrefix("$(") {
            text += " · \(gitCommitSHA)"
        }
        return text
    }
}
