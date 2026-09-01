import XCTest
@testable import BluegullAQIKit

/// The launch agent plist is the one copy of the helper's identity that
/// cannot import `LocationHelperIdentity`, so nothing but this test stops
/// the two from drifting -- and a drift here fails silently and late:
/// launchd holds a pending request against a job that never checks in, or
/// `SMAppService` reports `.notFound` (bluegull-aqi-hib.3/hib.5/hib.11).
final class LocationHelperIdentityTests: XCTestCase {
    /// Resolved from this file rather than a bundle resource: the plist is a
    /// build input of the *app* target, not of this package, so it isn't
    /// copied anywhere `Bundle.module` could find it.
    private func launchAgentPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BluegullAQIKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BluegullAQIKit
            .deletingLastPathComponent()   // mac-app
            .appendingPathComponent("BluegullAQI/LaunchAgents")
            .appendingPathComponent(LocationHelperIdentity.plistName)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testLabelMatches() throws {
        let plist = try launchAgentPlist()
        XCTAssertEqual(plist["Label"] as? String, LocationHelperIdentity.launchAgentLabel)
    }

    func testActivityNameMatches() throws {
        let plist = try launchAgentPlist()
        let events = try XCTUnwrap(plist["LaunchEvents"] as? [String: Any])
        let activities = try XCTUnwrap(events["com.apple.xpc.activity"] as? [String: Any])
        XCTAssertEqual(
            Array(activities.keys), [LocationHelperIdentity.refreshActivityName],
            "the helper checks in by this exact name; an unmatched one is never woken"
        )
    }

    func testMachServiceNameMatches() throws {
        let plist = try launchAgentPlist()
        let services = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertEqual(Array(services.keys), [LocationHelperIdentity.machServiceName])
    }

    /// A sandboxed process may look up a global mach name only if it begins
    /// with one of its own application-group values -- so this prefix is
    /// what makes the app able to reach the helper at all, not a naming
    /// convention (bluegull-aqi-hib.11).
    func testMachServiceNameIsAppGroupPrefixed() {
        XCTAssertTrue(
            LocationHelperIdentity.machServiceName.hasPrefix(UserDefaultsCacheStore.appGroupIdentifier),
            "an app-group prefix is what the sandbox actually checks"
        )
    }

    /// bluegull-aqi-hib.2: the 2026-08-12 spike left an unremovable
    /// locationd grant on `solutions.bluegull.aqi.helper`, so a helper
    /// reusing it would silently inherit a grant and make every first-run
    /// test invalid.
    func testBundleIdentifierAvoidsTheBurntSpikeIdentifier() {
        XCTAssertNotEqual(LocationHelperIdentity.bundleIdentifier, "solutions.bluegull.aqi.helper")
    }

    /// The plist reaches the executable by a bundle-relative path
    /// (SMAppService.h, so the app can be moved after install). Nothing else
    /// checks that the path it names is where the build actually puts the
    /// helper.
    func testBundleProgramPointsAtTheNestedHelperApp() throws {
        let plist = try launchAgentPlist()
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/Library/LoginItems/BluegullAQIHelper.app/Contents/MacOS/BluegullAQIHelper"
        )
    }

    /// The absence of these two is what makes this an on-demand agent rather
    /// than a login item that runs forever -- Steve's explicit requirement
    /// for the epic, and the easiest thing to reintroduce by accident while
    /// debugging why the helper isn't running.
    func testAgentIsOnDemandRatherThanLoginScoped() throws {
        let plist = try launchAgentPlist()
        XCTAssertNil(plist["RunAtLoad"], "RunAtLoad would make this a login item")
        XCTAssertNil(plist["KeepAlive"], "KeepAlive would make this resident by contract")
    }

    /// The wake interval is deliberately shorter than the cache's soft TTL,
    /// so a grace-period deferral can't leave the current-location slot
    /// stale for a whole extra cycle. `HelperRefreshJob.skippedStillFresh`
    /// is what keeps that from costing extra fetches -- the two are a pair,
    /// and raising this interval without understanding that reintroduces
    /// the staleness window.
    func testWakeIntervalStaysBelowTheSoftTTL() throws {
        let plist = try launchAgentPlist()
        let events = try XCTUnwrap(plist["LaunchEvents"] as? [String: Any])
        let activities = try XCTUnwrap(events["com.apple.xpc.activity"] as? [String: Any])
        let criteria = try XCTUnwrap(activities[LocationHelperIdentity.refreshActivityName] as? [String: Any])
        let interval = try XCTUnwrap(criteria["Interval"] as? Int)
        XCTAssertLessThan(TimeInterval(interval), AppGroupCache.defaultSoftTTL)
        XCTAssertNotNil(
            criteria["Delay"],
            "an Interval with no Delay implies a delay of HALF the interval (xpc/activity.h)"
        )
    }
}
