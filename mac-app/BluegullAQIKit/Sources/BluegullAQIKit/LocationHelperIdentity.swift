import Foundation

/// Every string the location helper agent (bluegull-aqi-hib) is identified
/// by, in one place because three separate artifacts have to agree on them
/// exactly and nothing catches a mismatch at build time:
///
/// - the helper's own executable, which checks in to the activity by name
///   and listens on the mach service by name;
/// - `mac-app/BluegullAQI/LaunchAgents/<plistName>`, which declares both;
/// - the container app, which registers the agent by plist name and pokes
///   it by mach service name.
///
/// A typo in any one of them fails silently and late -- launchd holds a
/// pending request against a job that never checks in, or `SMAppService`
/// reports `.notFound` -- which is exactly the class of failure
/// bluegull-aqi-hib.7 exists to make visible. The plist is the one copy
/// that cannot import this type; `LocationHelperIdentityTests` asserts the
/// two agree by reading the plist off disk.
public enum LocationHelperIdentity {
    /// DELIBERATELY NOT `solutions.bluegull.aqi.helper` (bluegull-aqi-hib.2):
    /// the 2026-08-12 spike left a real, still-present locationd grant for
    /// that identifier in /var/db/locationd/clients.plist, and it cannot be
    /// removed -- `tccutil` has no authority over locationd-managed Location
    /// grants and fails -10814. A helper reusing that id would silently
    /// inherit a grant, skip the first-run prompt, and make any test of the
    /// genuine first-run experience invalid.
    ///
    /// The same one-way door applies to this identifier: once a build signed
    /// with a given identity earns a grant here, that combination is spent
    /// for first-run testing. Grants are pinned to bundle id **plus signing
    /// leaf**, so an Apple Development build and a Developer ID build are
    /// separate subjects -- a dev-signed run does not burn the shipping
    /// first run.
    public static let bundleIdentifier = "solutions.bluegull.aqi.locationhelper"

    /// launchd job label. Same string as the bundle id by convention, but
    /// they are independent things -- launchd matches on this, TCC on the
    /// bundle id.
    public static let launchAgentLabel = bundleIdentifier

    /// `SMAppService.agent(plistName:)` resolves this against the container
    /// app's own `Contents/Library/LaunchAgents` -- per SMAppService.h that
    /// path is not negotiable, which is why project.yml carries a copy
    /// phase for it rather than treating it as packaging taste.
    public static let plistName = "\(launchAgentLabel).plist"

    /// The repeating XPC activity declared under the plist's `LaunchEvents`
    /// and checked in to with `XPC_ACTIVITY_CHECK_IN`. Declaring criteria in
    /// the plist rather than calling `xpc_activity_register` with them in
    /// code is what removes the bootstrap hole: launchd knows the schedule
    /// at registration time, so it can start a helper that has never run
    /// and whose container app may never be launched again. Measured over
    /// 247 wakes and a cold boot in spike/hib10 (bluegull-aqi-hib.10).
    public static let refreshActivityName = "\(launchAgentLabel).refresh"

    /// Lets the app start the helper at a moment of its own choosing rather
    /// than waiting for the activity to fire -- which bluegull-aqi-hib.6's
    /// first-run design needs, because a location prompt has to arrive
    /// while the user is still looking at the thing that asked for it.
    ///
    /// The app-group prefix is load-bearing, not cosmetic: a sandboxed
    /// process may only look up a global mach name beginning with one of
    /// its own `com.apple.security.application-groups` values. That is the
    /// route that needs no entitlement beyond the App Group both processes
    /// already share, so bluegull-aqi-fw4.8's App Review surface does not
    /// grow. Confirmed working between two sandboxed processes in
    /// spike/hib10 (bluegull-aqi-hib.11), against a negative control on a
    /// team-identifier-prefixed name that the sandbox refused.
    public static let machServiceName = "\(UserDefaultsCacheStore.appGroupIdentifier).locationhelper"

    /// Unified-log subsystem. The helper's own lifecycle is only observable
    /// after the fact -- nobody is watching when launchd wakes it at 3am --
    /// so bluegull-aqi-hib.9's verification reads back from here. Log at
    /// `.notice`, never `.debug`: `.debug` is memory-only and is gone by
    /// the time anyone looks, which cost a day of the hib.10 spike.
    public static let logSubsystem = "solutions.bluegull.aqi"
    public static let logCategory = "locationhelper"

    // MARK: - XPC message keys

    /// The requests the mach service accepts. Kept as constants rather than
    /// bare literals at both ends for the same drift reason as the names
    /// above.
    public static let xpcActionKey = "action"
    /// Resolve, fetch, write the cache. Never prompts -- if there is no
    /// grant it reports that and stops.
    public static let xpcRefreshAction = "refresh"
    /// bluegull-aqi-hib.6's first run, and the ONLY path on which the helper
    /// calls `requestWhenInUseAuthorization`. Deliberately a separate action
    /// rather than a flag on `refresh`: the system prompt is one-shot and
    /// unrecoverable once answered, so the ability to trigger it should be
    /// something a caller has to name, never something a routine refresh
    /// could do by accident.
    public static let xpcRequestAuthorizationAction = "request-authorization"
    /// Reply keys -- `outcome` carries `HelperRefreshJob.Outcome.label`, so
    /// the app learns what actually happened rather than only that the
    /// helper was reachable.
    public static let xpcOutcomeKey = "outcome"
    public static let xpcPidKey = "pid"
    /// `LocationHelperAuthorization.rawValue` as the helper saw it when it
    /// finished. Also written to `LocationHelperStatusStore`, which is what
    /// a caller that wasn't waiting reads instead.
    public static let xpcAuthorizationKey = "authorization"
}
