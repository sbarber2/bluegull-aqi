import CoreLocation
import Foundation

public enum LocationResolverError: Error, Equatable, Sendable {
    /// Location access isn't authorized. This type never requests
    /// authorization itself -- permission UX/timing is app-level policy
    /// (bluegull-aqi-e70.2), not this package's job.
    case permissionDenied
    case locationUnavailable(String)
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

/// Wraps `CLLocationManager`. Requests a single location fix per call
/// (`requestLocation()`, not continuous updates) -- appropriate for "where
/// is the user right now," not live tracking.
///
/// Not verified live: CoreLocation's authorization flow needs a properly
/// signed, entitled app with an `Info.plist` usage-description string,
/// none of which a bare Swift package test target has -- the same
/// entitlement barrier hit verifying bluegull-aqi-10h.5's Keychain code.
/// Real verification happens once this is wired into the actual app.
///
/// Not safe to call `currentLocation()` concurrently on the same instance
/// -- each call replaces the in-flight delegate. Callers should await one
/// request before starting another, which matches how this is actually
/// used (a single "get my location" action, not concurrent fan-out).
public final class SystemLocationProvider: NSObject, LocationProvider, @unchecked Sendable {
    private let manager: CLLocationManager
    private var activeDelegate: LocationRequestDelegate?

    override public init() {
        manager = CLLocationManager()
        super.init()
    }

    public func currentLocation() async throws -> Location {
        switch manager.authorizationStatus {
        case .denied, .restricted, .notDetermined:
            throw LocationResolverError.permissionDenied
        default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LocationRequestDelegate(continuation: continuation)
            activeDelegate = delegate
            manager.delegate = delegate
            manager.requestLocation()
        }
    }
}

private final class LocationRequestDelegate: NSObject, CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<Location, Error>?

    init(continuation: CheckedContinuation<Location, Error>) {
        self.continuation = continuation
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        continuation?.resume(returning: Location(latitude: coordinate.latitude, longitude: coordinate.longitude))
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: LocationResolverError.locationUnavailable(error.localizedDescription))
        continuation = nil
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
