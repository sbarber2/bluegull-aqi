import XCTest
@testable import BluegullAQIKit

/// Uses InMemoryKeychain, never the real system Keychain -- a bare
/// `swift test` process isn't a signed, entitled app bundle, and writing
/// real persistent state to the developer's actual login keychain from an
/// automated test run is exactly the kind of side effect to avoid
/// (bluegull-aqi-10h.5).
final class AirNowAPIKeyStoreTests: XCTestCase {
    private func makeStore() -> AirNowAPIKeyStore {
        AirNowAPIKeyStore(keychain: InMemoryKeychain())
    }

    func testLoadReturnsNilWhenNothingSaved() throws {
        let store = makeStore()
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = makeStore()
        try store.save("test-airnow-key-12345")
        XCTAssertEqual(try store.load(), "test-airnow-key-12345")
    }

    func testSaveOverwritesPreviousValue() throws {
        let store = makeStore()
        try store.save("first-key")
        try store.save("second-key")
        XCTAssertEqual(try store.load(), "second-key")
    }

    func testDeleteRemovesTheKey() throws {
        let store = makeStore()
        try store.save("test-airnow-key-12345")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testDeleteWhenNothingSavedDoesNotThrow() throws {
        let store = makeStore()
        XCTAssertNoThrow(try store.delete())
    }

    func testTwoStoresWithDifferentKeychainsAreIndependent() throws {
        // Sanity check that AirNowAPIKeyStore doesn't accidentally share
        // state across instances via shared mutable statics.
        let storeA = AirNowAPIKeyStore(keychain: InMemoryKeychain())
        let storeB = AirNowAPIKeyStore(keychain: InMemoryKeychain())

        try storeA.save("key-a")
        XCTAssertNil(try storeB.load())
    }
}
