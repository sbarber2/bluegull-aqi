import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// bluegull-aqi-hib.7's popover notice. Every one of these states is
/// reachable only by disabling a background item, spending a one-shot
/// system prompt, or damaging an install -- so none of them gets exercised
/// by hand during ordinary development, and a crash or a truncated layout
/// in one would ship unnoticed.
final class BackgroundRefreshNoticeRenderTests: XCTestCase {
    @MainActor
    private func render(_ status: BackgroundRefreshStatus) {
        let renderer = ImageRenderer(
            content: AQIPopoverView(
                reading: nil,
                lastError: nil,
                lastFetchedAt: nil,
                onLocationChange: {},
                backgroundRefresh: status,
                locationResolver: .fake(reverseGeocoding: .failure(.noResults))
            )
        )
        XCTAssertNotNil(renderer.nsImage, "\(status) failed to render")
    }

    @MainActor
    func testEveryStateRendersWithoutCrashing() {
        for status in BackgroundRefreshStatus.allCases {
            render(status)
        }
    }

    /// The working case must add nothing at all -- a notice that renders
    /// "successfully" while quietly occupying space in the healthy popover
    /// would be a regression nobody notices in a render test that only
    /// checks for nil.
    @MainActor
    func testTheWorkingStateContributesNoNotice() {
        XCTAssertNil(BackgroundRefreshStatus.working.explanation)
        XCTAssertEqual(BackgroundRefreshStatus.working.recovery.buttonTitle, nil)
    }
}
