import Foundation

/// Human-readable "which build is this" string (bluegull-aqi-fw4.9) --
/// surfaced at the bottom of `SettingsView` so a tester can read off
/// exactly what they're running instead of every ad-hoc build looking like
/// an indistinguishable "1.0".
///
/// `MARKETING_VERSION`/`CFBundleShortVersionString` is hand-bumped in
/// project.yml at real milestones. `CURRENT_PROJECT_VERSION`/
/// `CFBundleVersion` and `GitCommitSHA` are both stamped in at build time
/// from git state (see the Makefile's `XCODEBUILD_VERSION_OVERRIDES`), not
/// maintained by hand -- so this reads whatever actually got baked into the
/// bundle, not a value this type computes itself.
enum AppVersionInfo {
    static var current: String {
        displayString(
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            gitCommitSHA: Bundle.main.infoDictionary?["GitCommitSHA"] as? String
        )
    }

    static func displayString(shortVersion: String?, buildNumber: String?, gitCommitSHA: String?) -> String {
        let version = (shortVersion?.isEmpty == false) ? shortVersion! : "?"
        let build = (buildNumber?.isEmpty == false) ? buildNumber! : "?"
        var text = "v\(version) (\(build))"

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
