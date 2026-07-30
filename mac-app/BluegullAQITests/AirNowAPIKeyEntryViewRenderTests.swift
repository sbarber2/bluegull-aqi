import XCTest
import SwiftUI
import BluegullAQIKit
@testable import BluegullAQI

/// Lightweight smoke test (same rationale as `AQIPopoverViewRenderTests`/
/// `DataSourceModeToggleRenderTests`). The actual Keychain read/write logic
/// is already thoroughly tested at the `AirNowAPIKeyStore` level in
/// `BluegullAQIKitTests`; this just confirms the view itself renders
/// without crashing, for both the no-saved-key and a-key-exists cases.
///
/// `KeychainStore` is public, but the in-memory fake in `BluegullAQIKitTests`
/// is a test-only file private to that target -- not visible here (same
/// cross-module limitation as `InMemorySharedCacheStore`). A small local
/// fake instead.
final class AirNowAPIKeyEntryViewRenderTests: XCTestCase {
    private final class FakeKeychainStore: KeychainStore {
        private var values: [String: String] = [:]

        init(prefilledValue: String? = nil, account: String = "airnow-api-key") {
            if let prefilledValue {
                values[account] = prefilledValue
            }
        }

        func load(query: KeychainQuery) throws -> String? {
            values[query.account]
        }

        func save(query: KeychainQuery, value: String) throws {
            values[query.account] = value
        }

        func delete(query: KeychainQuery) throws {
            values.removeValue(forKey: query.account)
        }
    }

    @MainActor
    func testRendersWithoutCrashingWithNoSavedKey() {
        let store = AirNowAPIKeyStore(keychain: FakeKeychainStore())
        let renderer = ImageRenderer(content: AirNowAPIKeyEntryView(store: store))
        XCTAssertNotNil(renderer.nsImage)
    }

    @MainActor
    func testRendersWithoutCrashingWithAnExistingSavedKey() {
        let store = AirNowAPIKeyStore(keychain: FakeKeychainStore(prefilledValue: "test-key-value"))
        let renderer = ImageRenderer(content: AirNowAPIKeyEntryView(store: store))
        XCTAssertNotNil(renderer.nsImage)
    }
}
