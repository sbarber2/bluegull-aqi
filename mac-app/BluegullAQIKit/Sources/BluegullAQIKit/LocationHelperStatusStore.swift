import Foundation

/// What the helper's location grant currently is, as last observed by the
/// helper itself (bluegull-aqi-hib.6/hib.7).
///
/// Deliberately its own enum rather than `CLAuthorizationStatus`: this
/// value is persisted and read across a process boundary, and a raw
/// framework enum's numeric values are the wrong thing to write to disk.
/// It also collapses distinctions the UI has no use for -- `.authorizedAlways`
/// and `.authorizedWhenInUse` both simply mean the helper can work.
public enum LocationHelperAuthorization: String, Sendable, Equatable, Codable {
    /// Never asked. The state of a fresh install before the first-run flow
    /// has run, and the only state from which a prompt is still possible.
    case notDetermined
    /// The user said no, or an administrator forbade it. Unrecoverable by
    /// us: CoreLocation refuses to re-prompt once answered, and the
    /// locationd record cannot be cleared (tccutil fails -10814). System
    /// Settings is the only remaining path.
    case refused
    case authorized
}

/// The helper's last known state, written by the helper and read by the app.
public struct LocationHelperState: Sendable, Equatable, Codable {
    public let authorization: LocationHelperAuthorization
    /// `HelperRefreshJob.Outcome.label` from the helper's most recent run,
    /// or nil if it hasn't run one yet. Deliberately the label rather than
    /// the outcome itself -- this is a status record, not a second copy of
    /// the reading, which already lives in the cache.
    public let lastOutcome: String?
    public let recordedAt: Date

    public init(authorization: LocationHelperAuthorization, lastOutcome: String?, recordedAt: Date) {
        self.authorization = authorization
        self.lastOutcome = lastOutcome
        self.recordedAt = recordedAt
    }
}

/// The one channel by which the app learns whether the helper can actually
/// do its job (bluegull-aqi-hib.6).
///
/// This exists because the app CANNOT find out any other way. A location
/// grant belongs to a bundle identifier, and there is no API for one
/// process to ask what another bundle's TCC state is -- deliberately so.
/// `SMAppService.status` answers a different question ("is the agent
/// registered and approved"), and a helper can be perfectly registered and
/// still have been refused location. Under bluegull-aqi-hib.6's Option 1
/// the app has no location grant of its own to consult either, by design.
/// So the helper has to write down what it learned, and this is where.
///
/// Stored in the App Group suite alongside the cache, under a key outside
/// `AppGroupCache`'s own `aqi-cache-` prefix -- that prefix is swept on
/// every `put()`, and anything inside it that doesn't decode as an
/// `AQICacheEntry` is deleted as junk.
public struct LocationHelperStatusStore: Sendable {
    private static let key = "location-helper-state"

    /// A SEPARATE key from `key` above, deliberately: the two records have
    /// different writers -- the helper writes its own authorization, the
    /// app writes what `SMAppService` reports -- and neither can see the
    /// other's process. One key would mean two processes read-modify-
    /// writing the same value, where whichever wrote last silently erases
    /// the other's half.
    private static let availabilityKey = "location-helper-availability"

    private let store: SharedCacheStore

    public init(store: SharedCacheStore) {
        self.store = store
    }

    /// nil before the helper has ever run -- distinct from
    /// `.notDetermined`, which means the helper HAS run and found no grant.
    /// The difference matters to the app: nothing recorded at all is also
    /// what "the agent was never registered" looks like.
    public func current() -> LocationHelperState? {
        guard let data = store.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(LocationHelperState.self, from: data)
    }

    /// The app's view of whether the agent is registered and approved
    /// (bluegull-aqi-hib.7). Written by the CONTAINER APP, because
    /// `SMAppService` is unavailable to the widget extension -- app
    /// extensions cannot manage services -- so this record is the widget's
    /// only route to the answer.
    public func recordAvailability(_ availability: LocationHelperAvailability) {
        guard let data = try? JSONEncoder().encode(availability) else { return }
        store.set(data, forKey: Self.availabilityKey)
    }

    /// nil before the app has polled even once this install.
    public func availability() -> LocationHelperAvailability? {
        guard let data = store.data(forKey: Self.availabilityKey) else { return nil }
        return try? JSONDecoder().decode(LocationHelperAvailability.self, from: data)
    }

    /// The one answer both surfaces render from -- see
    /// `BackgroundRefreshStatus` on why this is derived in shared code
    /// rather than independently on each side.
    public func backgroundRefreshStatus() -> BackgroundRefreshStatus {
        BackgroundRefreshStatus.derive(availability: availability(), helperState: current())
    }

    /// Called by the helper after every run, so a grant revoked in System
    /// Settings shows up on the next wake rather than never -- there is no
    /// notification for that change, and this record is the only place the
    /// app could learn about it.
    public func record(
        authorization: LocationHelperAuthorization,
        lastOutcome: String?,
        now: Date = Date()
    ) {
        let state = LocationHelperState(
            authorization: authorization,
            lastOutcome: lastOutcome,
            recordedAt: now
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Writing through `SharedCacheStore` rather than `UserDefaults`
        // directly also means this posts `CacheChangeBroadcast`, so an app
        // that is open while the helper answers a prompt learns about it
        // without polling.
        store.set(data, forKey: Self.key)
    }
}
