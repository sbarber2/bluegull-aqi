import XCTest
@testable import BluegullAQIKit

/// bluegull-aqi-hib.8. The migration itself is close to trivial -- the app
/// simply stops resolving location and the helper starts -- so the work
/// here is the part that isn't: making sure an upgrading user is told WHY a
/// product they already granted location to is asking again.
final class HelperMigrationTests: XCTestCase {
    private func store(previouslyFetched: Bool) -> InMemorySharedCacheStore {
        let store = InMemorySharedCacheStore()
        if previouslyFetched {
            AppGroupCache(store: store).recordSuccessfulFetch()
        }
        return store
    }

    func testAnInstallWithPriorDataIsRecordedAsAnUpgrade() {
        let subject = LocationHelperStatusStore(store: store(previouslyFetched: true))

        subject.recordMigrationIfNeeded(hadPreviousData: true)

        XCTAssertTrue(subject.upgradedFromPreHelperBuild())
    }

    func testAFreshInstallIsNot() {
        let subject = LocationHelperStatusStore(store: store(previouslyFetched: false))

        subject.recordMigrationIfNeeded(hadPreviousData: false)

        XCTAssertFalse(subject.upgradedFromPreHelperBuild())
    }

    /// The reason this is recorded rather than computed on demand. "Has
    /// this install ever fetched?" is only a valid upgrade test at the very
    /// first launch of a helper-aware build; a fresh install that has since
    /// added a pinned location answers yes too, and would be told it
    /// upgraded from something it never had.
    func testAFreshInstallThatLaterFetchesIsStillNotAnUpgrade() {
        let store = self.store(previouslyFetched: false)
        let subject = LocationHelperStatusStore(store: store)
        subject.recordMigrationIfNeeded(hadPreviousData: false)

        // Time passes; the user pins a location and it fetches.
        AppGroupCache(store: store).recordSuccessfulFetch()
        subject.recordMigrationIfNeeded(hadPreviousData: true)

        XCTAssertFalse(subject.upgradedFromPreHelperBuild(), "the first answer must stand")
    }

    func testTheFirstAnswerIsNeverRevised() {
        let subject = LocationHelperStatusStore(store: store(previouslyFetched: true))
        let first = subject.recordMigrationIfNeeded(hadPreviousData: true)

        let second = subject.recordMigrationIfNeeded(hadPreviousData: false)

        XCTAssertEqual(first, second)
    }

    // MARK: - The copy an upgrading user actually reads

    /// This issue's acceptance criterion: a declined prompt must be
    /// explained in terms of the upgrade, not as a generic error. Asserted
    /// as "differs from the fresh-install wording" rather than by matching
    /// exact strings, so the copy stays editable.
    func testTheStatesAnUpgradingUserCanLandInSaySomethingDifferent() {
        for state in [BackgroundRefreshStatus.neverSetUp, .permissionNotGranted, .permissionRefused] {
            let fresh = state.explanation(afterUpgrade: false)
            let upgraded = state.explanation(afterUpgrade: true)
            XCTAssertNotNil(upgraded)
            XCTAssertNotEqual(fresh, upgraded, "\(state) reads identically before and after an upgrade")
        }
    }

    /// Everything else has nothing to do with upgrading, and inventing
    /// upgrade wording for it would be noise -- a login item switched off
    /// months later is not a migration story.
    func testEveryOtherStateReadsTheSameEitherWay() {
        let migrationStates: Set<BackgroundRefreshStatus> = [.neverSetUp, .permissionNotGranted, .permissionRefused]
        for state in BackgroundRefreshStatus.allCases where !migrationStates.contains(state) {
            XCTAssertEqual(
                state.explanation(afterUpgrade: false),
                state.explanation(afterUpgrade: true),
                "\(state) has no business mentioning an upgrade"
            )
        }
    }

    /// hib.8 is explicit that pinned locations are unaffected end to end.
    /// They never needed a location grant, so an upgrade mid-flight must
    /// not disturb them.
    func testPinnedDataSurvivesTheMigrationRecord() {
        let store = self.store(previouslyFetched: true)
        let pinned = Location(latitude: 37.7749, longitude: -122.4194)
        let cache = AppGroupCache(store: store)
        cache.put(AQIReading(location: pinned, pollutants: []), for: pinned)

        LocationHelperStatusStore(store: store).recordMigrationIfNeeded(hadPreviousData: true)

        XCTAssertNotNil(cache.get(for: pinned), "the upgrade must not disturb pinned data")
    }
}
