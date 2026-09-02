import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.7. The detection is the hard part of that issue -- there
/// is no notification when a user disables a background item, so this
/// derivation is what stands between the user and a silent, permanent
/// failure of Current Location.
final class BackgroundRefreshStatusTests: XCTestCase {
    private let now = Date()

    private func status(
        _ availability: LocationHelperAvailability?,
        _ authorization: LocationHelperAuthorization? = nil,
        lastWroteSecondsAgo: TimeInterval = 0
    ) -> BackgroundRefreshStatus {
        BackgroundRefreshStatus.derive(
            availability: availability,
            helperState: authorization.map {
                LocationHelperState(
                    authorization: $0,
                    lastOutcome: nil,
                    recordedAt: now.addingTimeInterval(-lastWroteSecondsAgo)
                )
            },
            now: now
        )
    }

    // MARK: - Enabled, approved, granted -- and still not running

    /// Regression for a failure measured on a real machine 2026-09-02: an
    /// agent whose Background Task Management record pinned a code
    /// requirement its rebuilt executable no longer satisfied failed to
    /// spawn with EX_CONFIG and was retried by launchd every 10 seconds --
    /// 3,452 times in twelve hours. `SMAppService.status` said `.enabled`
    /// throughout, and the last recorded authorization was `.authorized`,
    /// so every other signal here insisted everything was fine. Silence is
    /// the only thing that gave it away.
    func testAnAgentThatStoppedWritingIsNotReportedAsWorking() {
        let justBeyond = BackgroundRefreshStatus.silenceImpliesNotWaking + 60

        XCTAssertEqual(status(.enabled, .authorized, lastWroteSecondsAgo: justBeyond), .notWaking)
    }

    /// The threshold has to clear the honest worst case -- a 30-minute wake
    /// interval plus a 15-minute grace period -- and a machine that slept.
    /// A false alarm on a working install is worse than a beat of silence.
    func testAnOrdinaryGapBetweenWakesIsNotAnAlarm() {
        XCTAssertEqual(status(.enabled, .authorized, lastWroteSecondsAgo: 45 * 60), .working)
        XCTAssertEqual(status(.enabled, .authorized, lastWroteSecondsAgo: 4 * 3600), .working)
    }

    /// Silence only means "not waking" when everything else says it should
    /// be. Without a grant it has a better explanation already, and telling
    /// the user to re-register would be the wrong fix.
    func testSilenceDoesNotOverrideAMoreSpecificExplanation() {
        let old = BackgroundRefreshStatus.silenceImpliesNotWaking + 60

        XCTAssertEqual(status(.enabled, .refused, lastWroteSecondsAgo: old), .permissionRefused)
        XCTAssertEqual(status(.enabled, .notDetermined, lastWroteSecondsAgo: old), .permissionNotGranted)
        XCTAssertEqual(status(.notRegistered, .authorized, lastWroteSecondsAgo: old), .turnedOff)
    }

    // MARK: - The distinction the framework can't make

    /// `SMAppService` reports `.notRegistered` both for a fresh install and
    /// for one the user switched off in Login Items & Extensions. They need
    /// opposite copy -- "set this up" versus "this got turned off" -- so the
    /// helper having ever run is what separates them.
    func testNeverRegisteredAndSwitchedOffAreToldApartByWhetherTheHelperEverRan() {
        XCTAssertEqual(status(.notRegistered, nil), .neverSetUp)
        XCTAssertEqual(status(.notRegistered, .authorized), .turnedOff)
        XCTAssertEqual(status(.notRegistered, .notDetermined), .turnedOff)
    }

    // MARK: - Enabled, but that alone proves nothing

    /// Registered and approved says only that the agent MAY run. Whether it
    /// can do its job is a separate grant, on a separate bundle, that the
    /// app cannot query directly -- which is the whole reason
    /// LocationHelperStatusStore exists.
    func testEnabledStillDependsOnTheHelpersOwnLocationGrant() {
        XCTAssertEqual(status(.enabled, .authorized), .working)
        XCTAssertEqual(status(.enabled, .notDetermined), .permissionNotGranted)
        XCTAssertEqual(status(.enabled, .refused), .permissionRefused)
    }

    /// The gap between the app registering the agent and its first wake.
    /// Nothing is wrong yet, and claiming otherwise would put a warning in
    /// front of every user for the first few minutes of a successful setup.
    func testEnabledButNotYetRunIsNotAFailure() {
        XCTAssertEqual(status(.enabled, nil), .working)
    }

    func testRemainingAvailabilitiesMapStraightThrough() {
        XCTAssertEqual(status(.requiresApproval, .authorized), .needsApproval)
        XCTAssertEqual(status(.notFound, .authorized), .bundleMissing)
        XCTAssertEqual(status(.unreachable, .authorized), .unreachable)
    }

    /// Before the app has polled even once. A wrong alarm on a working
    /// install is worse than a beat of silence, so this must not invent a
    /// failure.
    func testNothingObservedYetNeverReportsAFailure() {
        XCTAssertEqual(status(nil, nil), .neverSetUp)
        XCTAssertEqual(status(nil, .authorized), .working)
    }

    // MARK: - Every non-working state must be actionable

    /// This issue's acceptance criteria require an explanation AND a way
    /// back, not just an accurate diagnosis. Asserted over allCases so a
    /// state added later cannot quietly ship with neither.
    func testEveryFailingStateExplainsItselfAndTheWorkingOneStaysSilent() {
        for state in BackgroundRefreshStatus.allCases {
            if state.isWorking {
                XCTAssertNil(state.explanation, "\(state) must render nothing at all")
                XCTAssertNil(state.widgetCaption)
                XCTAssertEqual(state.recovery, .none)
            } else {
                XCTAssertNotNil(state.explanation, "\(state) has no explanation")
                XCTAssertNotNil(state.widgetCaption, "\(state) has no widget caption")
            }
        }
    }

    /// The two we cannot fix from inside the app -- an unapproved
    /// background item, and a grant CoreLocation will not re-prompt for --
    /// must actually take the user somewhere. A button that goes nowhere is
    /// worse than no button.
    func testSettingsRecoveriesCarryAWorkingURLAndTheOthersDont() {
        XCTAssertNotNil(BackgroundRefreshStatus.needsApproval.recovery.settingsURL)
        XCTAssertNotNil(BackgroundRefreshStatus.permissionRefused.recovery.settingsURL)
        XCTAssertNil(BackgroundRefreshStatus.turnedOff.recovery.settingsURL, "handled in-app")
        for state in BackgroundRefreshStatus.allCases where state.recovery != .none {
            XCTAssertNotNil(state.recovery.buttonTitle, "\(state) offers a recovery with no button label")
        }
    }

    /// A refusal is permanent -- CoreLocation will not ask again and the
    /// locationd record cannot be cleared -- so offering our own re-askable
    /// flow there would be a button that silently does nothing.
    func testARefusalIsNeverOfferedTheInAppFlow() {
        XCTAssertEqual(BackgroundRefreshStatus.permissionRefused.recovery, .locationPrivacySettings)
        XCTAssertNotEqual(BackgroundRefreshStatus.permissionRefused.recovery, .turnOnInApp)
    }

    // MARK: - Round trip through the shared store

    /// The app writes availability, the helper writes authorization, and
    /// they must not clobber each other -- different processes, neither
    /// able to see the other's write.
    func testAppAndHelperWritesCoexistInTheSharedStore() {
        let subject = LocationHelperStatusStore(store: InMemorySharedCacheStore())

        subject.record(authorization: .authorized, lastOutcome: "refreshed")
        subject.recordAvailability(.enabled)

        XCTAssertEqual(subject.backgroundRefreshStatus(), .working)
        XCTAssertEqual(subject.current()?.authorization, .authorized, "the app's write must not erase the helper's")

        // The user switches it off in System Settings; only the app notices.
        subject.recordAvailability(.notRegistered)

        XCTAssertEqual(subject.backgroundRefreshStatus(), .turnedOff)
        XCTAssertEqual(subject.current()?.lastOutcome, "refreshed", "still intact")
    }
}
