import BluegullAQIKit

/// Fakes for LocationResolverTests -- never touches real CoreLocation
/// (bluegull-aqi-10h.6). CI can't exercise real GPS or live geocoding.
struct FakeLocationProvider: LocationProvider {
    enum Result {
        case success(Location)
        case failure(LocationResolverError)
    }

    let result: Result

    func currentLocation() async throws -> Location {
        switch result {
        case .success(let location):
            return location
        case .failure(let error):
            throw error
        }
    }
}

struct FakeAddressGeocoder: AddressGeocoder {
    enum Result {
        case success(Location)
        case failure(LocationResolverError)
    }

    let result: Result

    func geocode(_ query: String) async throws -> Location {
        switch result {
        case .success(let location):
            return location
        case .failure(let error):
            throw error
        }
    }
}
