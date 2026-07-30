import XCTest
@testable import BluegullAQIKit

final class LocationResolverTests: XCTestCase {
    private let sampleLocation = Location(latitude: 37.7749, longitude: -122.4194)

    func testCurrentLocationReturnsProviderResult() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .success(sampleLocation)),
            geocoder: FakeAddressGeocoder(result: .failure(.noResults))
        )
        let location = try await resolver.currentLocation()
        XCTAssertEqual(location, sampleLocation)
    }

    func testCurrentLocationPropagatesPermissionDenied() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .failure(.permissionDenied)),
            geocoder: FakeAddressGeocoder(result: .failure(.noResults))
        )
        do {
            _ = try await resolver.currentLocation()
            XCTFail("Expected LocationResolverError.permissionDenied")
        } catch LocationResolverError.permissionDenied {
            // expected
        }
    }

    func testCurrentLocationPropagatesLocationUnavailable() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .failure(.locationUnavailable("GPS signal lost"))),
            geocoder: FakeAddressGeocoder(result: .failure(.noResults))
        )
        do {
            _ = try await resolver.currentLocation()
            XCTFail("Expected LocationResolverError.locationUnavailable")
        } catch LocationResolverError.locationUnavailable(let message) {
            XCTAssertEqual(message, "GPS signal lost")
        }
    }

    func testResolveAddressReturnsGeocoderResult() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .failure(.permissionDenied)),
            geocoder: FakeAddressGeocoder(result: .success(sampleLocation))
        )
        let location = try await resolver.resolve(address: "San Francisco, CA")
        XCTAssertEqual(location, sampleLocation)
    }

    func testResolveAddressPropagatesNoResults() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .failure(.permissionDenied)),
            geocoder: FakeAddressGeocoder(result: .failure(.noResults))
        )
        do {
            _ = try await resolver.resolve(address: "not a real place at all")
            XCTFail("Expected LocationResolverError.noResults")
        } catch LocationResolverError.noResults {
            // expected
        }
    }

    func testResolveAddressPropagatesGeocodingFailed() async throws {
        let resolver = LocationResolver(
            locationProvider: FakeLocationProvider(result: .failure(.permissionDenied)),
            geocoder: FakeAddressGeocoder(result: .failure(.geocodingFailed("network error")))
        )
        do {
            _ = try await resolver.resolve(address: "San Francisco, CA")
            XCTFail("Expected LocationResolverError.geocodingFailed")
        } catch LocationResolverError.geocodingFailed(let message) {
            XCTAssertEqual(message, "network error")
        }
    }
}
