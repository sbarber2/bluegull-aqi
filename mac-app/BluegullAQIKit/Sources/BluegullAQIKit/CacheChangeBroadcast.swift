import Foundation

/// Broadcasts "the shared App Group cache changed" across process boundaries
/// (bluegull-aqi-e70.49). `UserDefaults(suiteName:)` has no built-in
/// cross-process change notification of its own -- KVO on it only fires
/// in-process. A consumer like `WidgetDetailView` has no way to learn that a
/// DIFFERENT process (the widget extension, fetching its own pinned
/// locations independently since bluegull-aqi-mtm.24) just wrote fresher
/// data, short of polling.
///
/// Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) are
/// the standard low-level primitive for exactly this case: unlike
/// `DistributedNotificationCenter`, they need no extra entitlement beyond
/// the App Group these processes already share, and they deliberately carry
/// no payload -- every observer re-reads the authoritative shared store
/// itself on a signal, rather than trusting a payload that could itself be
/// racy/stale. That's also why this type has no "what changed" information
/// to offer -- callers already have `AppGroupCache`/`WidgetTimelineComputer`
/// for that; this only ever means "go re-read."
public enum CacheChangeBroadcast {
    private static let darwinName = "solutions.bluegull.aqi.cache-did-change" as CFString

    /// The in-process notification `changes()` actually observes -- see
    /// `installBridge()`'s own doc comment for why this two-hop design
    /// exists instead of observing the Darwin notification directly.
    private static let localNotificationName = Notification.Name("solutions.bluegull.aqi.cache-did-change.local")

    /// `let ... = installBridge()` runs exactly once per process, the first
    /// time either `post()` or `changes()` touches it -- Swift's own
    /// once-semantics for a static stored property, not a hand-rolled
    /// dispatch_once.
    private static let bridgeInstalled: Bool = installBridge()

    /// `CFNotificationCenterAddObserver`'s callback is a bare
    /// `@convention(c)` function pointer -- it cannot capture any Swift
    /// context, so it can't call back into arbitrary instance state
    /// directly (the classic workaround is threading an `Unmanaged`
    /// self-pointer through the `observer` argument, but that adds real
    /// complexity -- manual retain/release bookkeeping across a C boundary
    /// -- for no benefit here, since this broadcast has no per-instance
    /// identity to begin with). Installing ONE process-wide, permanent
    /// observer that just re-posts to `NotificationCenter.default`
    /// sidesteps that entirely: everything downstream (`changes()`) uses
    /// ordinary, safe, capturing Swift APIs (`NotificationCenter.
    /// addObserver`, `AsyncStream`) instead of C-callback/opaque-pointer
    /// plumbing. Deliberately never removed -- this bridge is meant to
    /// outlive the process, not any one subscriber (compare `changes()`'s
    /// own per-subscription observer below, which IS removed on
    /// termination).
    private static func installBridge() -> Bool {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: CacheChangeBroadcast.localNotificationName, object: nil)
            },
            darwinName,
            nil,
            .deliverImmediately
        )
        return true
    }

    /// Call after every real write to the shared cache. Posts across every
    /// process sharing this App Group (the container app and the widget
    /// extension alike), not just the caller's own -- see
    /// `UserDefaultsCacheStore.set`, the one real call site.
    public static func post() {
        _ = bridgeInstalled
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName),
            nil, nil, true
        )
    }

    /// An element per change -- from this process's own writes and any
    /// other process sharing the App Group. Never finishes on its own;
    /// cancelling the consuming `Task` (e.g. a SwiftUI `.task` going away)
    /// ends iteration and removes the underlying observer via
    /// `onTermination`, so nothing leaks past the subscriber's own
    /// lifetime. Safe to call `post()` before any subscriber exists, or
    /// after one goes away -- posting to zero observers is a no-op, not an
    /// error.
    public static func changes() -> AsyncStream<Void> {
        _ = bridgeInstalled
        return AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: localNotificationName, object: nil, queue: nil
            ) { _ in
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}

/// Something that can tell a caller "the shared cache changed, go re-read
/// it" -- abstracted so the real Darwin-notification-backed implementation
/// and a test double can both satisfy it, matching this package's existing
/// pattern of injectable real-vs-fake dependencies (e.g. `LocationResolver`).
public protocol CacheChangeObserving: Sendable {
    func changes() -> AsyncStream<Void>
}

/// The real implementation -- observes `CacheChangeBroadcast`.
public struct DarwinCacheChangeObserver: CacheChangeObserving {
    public init() {}

    public func changes() -> AsyncStream<Void> {
        CacheChangeBroadcast.changes()
    }
}
