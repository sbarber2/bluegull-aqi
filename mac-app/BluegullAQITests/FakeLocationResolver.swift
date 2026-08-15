import BluegullAQIKit

/// Shared fake for any render test exercising `ResolvedPlaceNameCaption`
/// (bluegull-aqi-e70.27, via `AQIPopoverView`/`WidgetDetailView`'s own
/// injectable `locationResolver`) -- never constructs a real
/// `LocationResolver()`, which would hit real CoreLocation/CLGeocoder, same
/// "never touches real CoreLocation in tests" reasoning as
/// `LocationResolverTests`' own fakes in `BluegullAQIKitTests`. A local
/// duplicate, not a shared import: app-extension/app-target test targets
/// can't be linked against each other's test-only files (same cross-module
/// limitation `AirNowAPIKeyEntryViewRenderTests`' own `FakeKeychainStore`
/// doc comment already covers).
private struct FakeLocationProvider: LocationProvider {
    func currentLocation() async throws -> Location {
        throw LocationResolverError.permissionDenied
    }
}

private struct FakeAddressGeocoder: AddressGeocoder {
    func geocode(_ query: String) async throws -> Location {
        throw LocationResolverError.noResults
    }
}

struct FakeReverseGeocoder: ReverseGeocoder {
    enum Result {
        case success(String)
        case failure(LocationResolverError)
    }

    let result: Result

    func placeName(for location: Location) async throws -> String {
        switch result {
        case .success(let name):
            return name
        case .failure(let error):
            throw error
        }
    }
}

extension LocationResolver {
    /// A resolver whose `placeName(for:)` returns `result` and never
    /// touches real CoreLocation/CLGeocoder for any of its three
    /// operations.
    static func fake(reverseGeocoding result: FakeReverseGeocoder.Result) -> LocationResolver {
        LocationResolver(
            locationProvider: FakeLocationProvider(),
            geocoder: FakeAddressGeocoder(),
            reverseGeocoder: FakeReverseGeocoder(result: result)
        )
    }
}
