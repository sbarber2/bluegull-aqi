import CoreLocation
import Foundation

public enum LocationResolverError: Error, Equatable, Sendable {
    /// Location access isn't authorized. This type never requests
    /// authorization itself -- permission UX/timing is app-level policy
    /// (bluegull-aqi-e70.2), not this package's job.
    case permissionDenied
    case locationUnavailable(String)
    /// CoreLocation never answered at all within the deadline
    /// (bluegull-aqi-10h.22) -- neither a fix nor an error arrived.
    /// Deliberately distinct from `.locationUnavailable`, which is
    /// CoreLocation actively *reporting* failure: this case is silence,
    /// and silence is what used to suspend the caller forever. The two
    /// want different responses -- a reported failure is worth surfacing
    /// to the user, whereas silence is usually transient and worth just
    /// retrying on the normal schedule. Carries the deadline that elapsed.
    case timedOut(TimeInterval)
    case geocodingFailed(String)
    /// The geocoder ran successfully but found nothing for the query.
    case noResults
}

/// Resolves "where is the user" for both supported modes (bluegull-aqi-10h.6):
/// current GPS location, and a user-pinned address/zip code. Both underlying
/// system frameworks (CoreLocation for GPS, CLGeocoder for address lookup)
/// sit behind injectable protocols -- CI can't exercise real GPS or live
/// geocoding, so tests use fakes, never `SystemLocationProvider`/
/// `SystemAddressGeocoder` directly.
public struct LocationResolver: Sendable {
    private let locationProvider: LocationProvider
    private let geocoder: AddressGeocoder
    private let reverseGeocoder: ReverseGeocoder

    public init(
        locationProvider: LocationProvider = SystemLocationProvider(),
        geocoder: AddressGeocoder = SystemAddressGeocoder(),
        reverseGeocoder: ReverseGeocoder = SystemReverseGeocoder()
    ) {
        self.locationProvider = locationProvider
        self.geocoder = geocoder
        self.reverseGeocoder = reverseGeocoder
    }

    /// The user's current GPS location. Throws `.permissionDenied` if
    /// location access isn't authorized -- this type doesn't prompt for
    /// authorization itself.
    public func currentLocation() async throws -> Location {
        try await locationProvider.currentLocation()
    }

    /// Resolves a free-form address or zip code to a coordinate, for a
    /// user-pinned location. Throws `.noResults` if nothing matches.
    public func resolve(address: String) async throws -> Location {
        try await geocoder.geocode(address)
    }

    /// Resolves a coordinate back to a human-readable place name --
    /// bluegull-aqi-e70.27, so "Current Location" can show what it actually
    /// resolved to, not just that synthetic label. Throws `.noResults` if
    /// nothing matches. Unlike `currentLocation()`, this never touches
    /// `CLLocationManager`/location authorization at all -- `CLGeocoder`
    /// reverse lookups need only network access, same as `resolve(address:)`.
    public func placeName(for location: Location) async throws -> String {
        try await reverseGeocoder.placeName(for: location)
    }
}

// MARK: - Protocols (for test injection)

public protocol LocationProvider: Sendable {
    func currentLocation() async throws -> Location
}

public protocol AddressGeocoder: Sendable {
    func geocode(_ query: String) async throws -> Location
}

public protocol ReverseGeocoder: Sendable {
    func placeName(for location: Location) async throws -> String
}

// MARK: - Real implementations

/// The slice of `CLLocationManager` that `SystemLocationProvider` actually
/// uses, so the deadline logic below is testable without CoreLocation
/// (bluegull-aqi-10h.22). Every other system dependency in this file was
/// already behind a protocol for exactly this reason; `CLLocationManager`
/// was the one that wasn't, which is precisely why "the request never
/// called back" had no test covering it and shipped as a hang.
protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: CLLocationManagerDelegate? { get set }
    func requestLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

/// Wraps `CLLocationManager`. Requests a single location fix per call
/// (`requestLocation()`, not continuous updates) -- appropriate for "where
/// is the user right now," not live tracking.
///
/// Every call is bounded by `timeout` (bluegull-aqi-10h.22).
/// `requestLocation()` promises a delegate callback "shortly," but in
/// practice it can go silent -- no fix obtainable, Wi-Fi positioning
/// unavailable with no GPS, location services wedged -- and the previous
/// version resumed its continuation *only* from the two delegate
/// callbacks, so silence suspended the caller forever. In the long-lived
/// menu bar app that is an invisible stall in one refresh cycle. In any
/// short-lived process holding a launchd transaction it means the process
/// never exits at all, which is why this surfaced while reviewing the
/// bluegull-aqi-hib helper design.
///
/// Not verified live: CoreLocation's authorization flow needs a properly
/// signed, entitled app with an `Info.plist` usage-description string,
/// none of which a bare Swift package test target has -- the same
/// entitlement barrier hit verifying bluegull-aqi-10h.5's Keychain code.
/// The *timeout* behaviour is unit-tested through `LocationManaging`; what
/// still needs a real app is the authorization flow itself.
///
/// Not safe to call `currentLocation()` concurrently on the same instance
/// -- each call replaces the in-flight request. Callers should await one
/// request before starting another, which matches how this is actually
/// used (a single "get my location" action, not concurrent fan-out).
public final class SystemLocationProvider: NSObject, LocationProvider, @unchecked Sendable {
    /// Deadline for a single fix. Chosen to match
    /// `RequestTimeoutStore.defaultServiceTimeout` in magnitude but
    /// deliberately NOT read from it -- that store configures *network*
    /// timeouts per data source, which is a different failure with
    /// different tuning pressure. A blown deadline here isn't fatal: the
    /// caller fails one cycle and `RefreshScheduler`'s fast-retry
    /// (bluegull-aqi-e70.47) picks it up 60s later.
    public static let defaultTimeout: TimeInterval = 15

    private let manager: LocationManaging
    private let timeout: TimeInterval
    /// Keeps the in-flight request alive: `CLLocationManager.delegate` is
    /// a weak reference, so nothing else retains it for the duration.
    private var activeRequest: LocationRequest?

    override public convenience init() {
        self.init(manager: CLLocationManager())
    }

    init(manager: LocationManaging, timeout: TimeInterval = SystemLocationProvider.defaultTimeout) {
        self.manager = manager
        self.timeout = timeout
        super.init()
    }

    public func currentLocation() async throws -> Location {
        switch manager.authorizationStatus {
        case .denied, .restricted, .notDetermined:
            throw LocationResolverError.permissionDenied
        default:
            break
        }

        let request = LocationRequest(manager: manager, timeout: timeout)
        activeRequest = request
        manager.delegate = request

        return try await withCheckedThrowingContinuation { continuation in
            // Arms the deadline as part of storing the continuation, so
            // there is no window where a caller is suspended with nothing
            // scheduled to wake it. Must precede `requestLocation()`, which
            // is free to call back synchronously.
            request.start(continuation)
            manager.requestLocation()
        }
    }
}

/// Owns exactly one in-flight `requestLocation()`: the continuation, the
/// deadline that guarantees it gets resumed, and the one lock that makes
/// "resume exactly once" true whichever of the three possible outcomes --
/// fix, CoreLocation error, timeout -- arrives first.
private final class LocationRequest: NSObject, CLLocationManagerDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Location, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    private let manager: LocationManaging
    private let timeout: TimeInterval

    init(manager: LocationManaging, timeout: TimeInterval) {
        self.manager = manager
        self.timeout = timeout
        super.init()
    }

    func start(_ continuation: CheckedContinuation<Location, Error>) {
        // `[weak self]` matters: the task retains what it captures, and
        // `self` retains the task -- a strong capture would keep both
        // alive past the request. The provider's `activeRequest` is what
        // holds `self` up for the request's real lifetime.
        let task = Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timeOut()
        }
        // Both under one lock, so a zero/near-zero deadline that fires
        // before this returns still sees a consistent request to finish.
        lock.lock()
        self.continuation = continuation
        timeoutTask = task
        lock.unlock()
    }

    private func timeOut() {
        guard finish(with: .failure(.timedOut(timeout))) else { return }
        // Only if this call actually won the race -- `stopUpdatingLocation()`
        // is what cancels a pending one-shot `requestLocation()`, and
        // there's no reason to call it against a request that already
        // completed. Hopped to the main queue because `CLLocationManager`
        // expects to be driven from a thread with a live run loop, and a
        // detached task's thread isn't one.
        let manager = self.manager
        DispatchQueue.main.async { manager.stopUpdatingLocation() }
    }

    /// The single exit for every outcome. Returns whether this call is the
    /// one that resumed the caller, so a loser (a fix that lands just after
    /// the deadline, say) can tell it lost rather than double-resuming --
    /// which traps on a `CheckedContinuation`.
    @discardableResult
    private func finish(with result: Result<Location, LocationResolverError>) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        continuation.resume(with: result.mapError { $0 as Error })
        return true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // An empty `locations` leaves the request pending on purpose --
        // there's nothing to report yet and another callback may follow.
        // Before bluegull-aqi-10h.22 that was another silent path to a
        // permanent hang; now the deadline backstops it.
        guard let coordinate = locations.last?.coordinate else { return }
        finish(with: .success(Location(latitude: coordinate.latitude, longitude: coordinate.longitude)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(.locationUnavailable(error.localizedDescription)))
    }
}

/// Wraps `CLGeocoder` for resolving a user-pinned address/zip code -- no
/// backend geocoding endpoint needed. Not verified live, for the same
/// reason as `SystemLocationProvider` above (no signed app context in a
/// bare package test target); `CLGeocoder` doesn't require location
/// authorization the way `CLLocationManager` does, but network-dependent
/// geocoding still isn't something to run automatically in tests.
public final class SystemAddressGeocoder: AddressGeocoder, @unchecked Sendable {
    private let geocoder = CLGeocoder()

    public init() {}

    public func geocode(_ query: String) async throws -> Location {
        try await withCheckedThrowingContinuation { continuation in
            geocoder.geocodeAddressString(query) { placemarks, error in
                if let error {
                    continuation.resume(throwing: LocationResolverError.geocodingFailed(error.localizedDescription))
                    return
                }
                guard let coordinate = placemarks?.first?.location?.coordinate else {
                    continuation.resume(throwing: LocationResolverError.noResults)
                    return
                }
                continuation.resume(returning: Location(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
    }
}

/// Wraps `CLGeocoder`'s reverse lookup (bluegull-aqi-e70.27) -- same
/// not-verified-live caveat as `SystemAddressGeocoder` just above.
public final class SystemReverseGeocoder: ReverseGeocoder, @unchecked Sendable {
    private let geocoder = CLGeocoder()

    public init() {}

    public func placeName(for location: Location) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let clLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            geocoder.reverseGeocodeLocation(clLocation) { placemarks, error in
                if let error {
                    continuation.resume(throwing: LocationResolverError.geocodingFailed(error.localizedDescription))
                    return
                }
                guard let placemark = placemarks?.first else {
                    continuation.resume(throwing: LocationResolverError.noResults)
                    return
                }
                continuation.resume(returning: Self.formattedName(from: placemark))
            }
        }
    }

    /// "City, ST" when both are available and distinct; falls back through
    /// county/state/raw name for the sparser placemarks a rural coordinate
    /// can produce, rather than surfacing a blank or a crash.
    private static func formattedName(from placemark: CLPlacemark) -> String {
        let city = placemark.locality ?? placemark.subAdministrativeArea
        let region = placemark.administrativeArea
        if let city, let region, city != region {
            return "\(city), \(region)"
        }
        return city ?? region ?? placemark.name ?? "Unknown location"
    }
}
