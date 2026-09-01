import XCTest
import SwiftUI
@testable import BluegullAQI

/// bluegull-aqi-hib.6's first-run window. Same rationale as the other render
/// tests here: confirms every phase renders without crashing, which for a
/// view with a five-way switch on state is worth more than it sounds --
/// three of these phases are ones a developer will almost never reach by
/// hand, because getting to them means spending a one-shot system prompt.
///
/// Does NOT exercise `LocationSetupCoordinator.enable()`. That registers a
/// real background agent and can put a real system location dialog on
/// screen; running it as a side effect of the test suite would consume the
/// prompt on the developer's own machine, and the resulting locationd grant
/// cannot be removed (tccutil fails -10814).
final class LocationSetupViewRenderTests: XCTestCase {
    @MainActor
    private func render(_ phase: LocationSetupCoordinator.Phase, isUpgrade: Bool = false) {
        let coordinator = LocationSetupCoordinator(phase: phase)
        let renderer = ImageRenderer(
            content: LocationSetupView(coordinator: coordinator, isUpgrade: isUpgrade)
        )
        XCTAssertNotNil(renderer.nsImage, "phase \(phase) failed to render")
    }

    @MainActor func testRendersExplanation() { render(.explaining) }
    @MainActor func testRendersUpgradeExplanation() { render(.explaining, isUpgrade: true) }
    @MainActor func testRendersRegistering() { render(.registering) }
    @MainActor func testRendersWaitingForPermission() { render(.waitingForPermission) }
    @MainActor func testRendersGranted() { render(.granted) }
    @MainActor func testRendersRefused() { render(.refused) }
    @MainActor func testRendersUnanswered() { render(.unanswered) }
    @MainActor func testRendersFailure() { render(.failed("Something specific went wrong.")) }

    /// The two irreversible-vs-recoverable branches must not read the same.
    /// "Don't Allow" is permanent and has to say so and point at System
    /// Settings; an unanswered prompt cost nothing and must not tell the
    /// user their only option is System Settings.
    @MainActor
    func testRefusedAndUnansweredAreDifferentStates() {
        XCTAssertNotEqual(LocationSetupCoordinator.Phase.refused, .unanswered)
    }

    /// "Not now" has to leave the offer standing -- that is the entire
    /// reason our own re-askable pre-prompt sits in front of the system's
    /// one-shot one.
    @MainActor
    func testDecliningLeavesThePopoverOfferStanding() {
        let coordinator = LocationSetupCoordinator()
        coordinator.declineForNow()

        XCTAssertFalse(coordinator.shouldOfferSetupOnLaunch, "should stop volunteering at launch")
        // Independent of the decline flag by design: the popover keeps
        // offering for as long as the helper is off.
        XCTAssertTrue(LocationSetupCoordinator.shouldOfferSetupInPopover)

        // Leaves the app's own state clean for a later attempt.
        XCTAssertEqual(coordinator.phase, .explaining)
    }
}
