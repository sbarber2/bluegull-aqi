import CoreLocation
import Foundation

/// The slice of `CLLocationManager` needed to learn an authorization
/// status: the value, and somewhere to send the callback that says the
/// value is finally trustworthy.
///
/// Public so the helper agent -- a separate target -- can use the same
/// watcher the app does, which is the entire point of
/// bluegull-aqi-hib.13. Deliberately narrower than `LocationManaging`:
/// nothing here can request a location, let alone request authorization,
/// so widening this protocol is the one way this file could become a
/// second place that prompts.
public protocol LocationAuthorizationReporting: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: CLLocationManagerDelegate? { get set }
}

/// Waits for `CLLocationManager`'s first authorization callback, because
/// reading `authorizationStatus` before it arrives is a lie.
///
/// THE HAZARD, once, in one place. `CLLocationManager` populates
/// `authorizationStatus` asynchronously: it reports `.notDetermined` for
/// the first moments after construction whatever the real grant is, and
/// only becomes accurate once the manager has round-tripped with locationd.
/// A long-lived app rarely notices -- its manager settled minutes ago. A
/// short-lived helper woken by launchd constructs its manager and asks in
/// the same breath, which is the normal case for this whole epic.
///
/// This existed three times before this type did (bluegull-aqi-hib.13), and
/// each copy was written only after the bug had already shipped and been
/// found in the field:
///   - bluegull-aqi-hib.4, in `SystemLocationProvider`: a fully authorized
///     process told it had no permission.
///   - bluegull-aqi-hib.6, in the helper's request path.
///   - bluegull-aqi-hib.7 follow-up: the helper recorded
///     `authorization: notDetermined` into the shared state the app reads
///     while demonstrably authorized, which would have had the app tell an
///     authorized user to grant permission they already had.
/// Only the first was reachable from a test target at all. Hence one
/// implementation, tested, that all three call.
///
/// Assigning the delegate is itself what provokes the first callback, so
/// `install(on:)` and `settledStatus(fallingBackTo:)` are separate steps:
/// a caller that also intends to REQUEST authorization must do so between
/// them, while the delegate is live and before anything awaits.
public final class LocationAuthorizationWatcher: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    /// Bounds a manager that never calls back at all. Short, because the
    /// answer normally arrives on the first callback rather than by waiting
    /// this out -- this is a backstop against silence, the same failure
    /// bluegull-aqi-10h.22 fixed for location fixes themselves.
    public static let defaultTimeout: TimeInterval = 3

    /// Whether a `.notDetermined` callback counts as the answer.
    ///
    /// This is the ONE way the two callers legitimately differ, and getting
    /// it backwards is silently wrong in both directions. When OBSERVING,
    /// that callback IS the answer: it is the first trustworthy read, and
    /// "no grant yet" is a real state. When ASKING, it is merely the
    /// callback fired on delegate assignment before the user has touched
    /// the dialog -- resolving on it would report "declined" the instant we
    /// asked.
    private let resolvesOnNotDetermined: Bool

    private let timeout: TimeInterval
    /// The manager this watcher was installed on. Held so the callback can
    /// read ITS status rather than the argument's -- see
    /// `locationManagerDidChangeAuthorization`. No retain cycle:
    /// `CLLocationManager.delegate` is weak.
    private var reporter: LocationAuthorizationReporting?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var settled: CLAuthorizationStatus?
    private var timeoutTask: Task<Void, Never>?

    public init(
        timeout: TimeInterval = LocationAuthorizationWatcher.defaultTimeout,
        resolvesOnNotDetermined: Bool = true
    ) {
        self.timeout = timeout
        self.resolvesOnNotDetermined = resolvesOnNotDetermined
        super.init()
    }

    /// Becomes `manager`'s delegate, which provokes the first callback.
    ///
    /// Call on whatever thread owns the manager. `CLLocationManager`
    /// delivers delegate callbacks on the run loop of the thread that
    /// CREATED it, so a manager built on a queue without a run loop never
    /// calls back -- measured live 2026-09-01, where an approved prompt was
    /// never delivered and only the deadline's fallback noticed, 128
    /// seconds late. The caller owns that choice; this type only notes that
    /// it matters.
    ///
    /// The caller must keep this watcher alive until `settledStatus`
    /// returns: `CLLocationManager.delegate` is a weak reference.
    public func install(on manager: LocationAuthorizationReporting) {
        reporter = manager
        manager.delegate = self
    }

    /// The settled status. Resolves exactly once, from whichever of the
    /// callback and the deadline arrives first, and never hangs -- callers
    /// have transactions to end and replies to send whatever happened.
    ///
    /// `fallback` is read only if the deadline wins, so a manager that
    /// never called back still yields the best value available rather than
    /// a guess.
    public func settledStatus(
        fallingBackTo fallback: @escaping @Sendable () -> CLAuthorizationStatus
    ) async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            lock.lock()
            // The callback can land before this runs -- `install(on:)` has
            // already fired it. Recording an answer with nobody waiting is
            // what makes that safe.
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
                return
            }
            self.continuation = continuation
            timeoutTask = Task { [weak self, timeout] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(fallback())
            }
            lock.unlock()
        }
    }

    private func finish(_ status: CLAuthorizationStatus) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = status
        let continuation = self.continuation
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        continuation?.resume(returning: status)
    }

    /// Reads the status from the manager this watcher was INSTALLED on,
    /// not from the callback's argument.
    ///
    /// In production they are the same object, which is exactly why the
    /// difference is easy to miss -- and why it was: extracting this type
    /// (bluegull-aqi-hib.13) silently switched to the argument, and the
    /// only thing that noticed was hib.4's own regression test, whose fake
    /// manager necessarily passes a throwaway `CLLocationManager` to a
    /// delegate signature that demands a concrete one. Trusting the
    /// argument means trusting whatever the caller handed us about a
    /// manager we were not watching. Trusting the installed one is what
    /// makes `LocationAuthorizationReporting` a real seam instead of
    /// decoration.
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        report(reporter?.authorizationStatus ?? manager.authorizationStatus)
    }

    /// Split out so tests can drive it without a real `CLLocationManager`,
    /// which the delegate signature otherwise demands.
    func report(_ status: CLAuthorizationStatus) {
        guard resolvesOnNotDetermined || status != .notDetermined else { return }
        finish(status)
    }
}
