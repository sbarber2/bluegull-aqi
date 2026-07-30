import BluegullAQIKit
import Foundation

/// Fake `KeychainStore` for tests -- never touches the real macOS Keychain
/// (bluegull-aqi-10h.5). Not thread-safe; fine for single-threaded test use.
final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    private func key(for query: KeychainQuery) -> String {
        "\(query.service)|\(query.account)"
    }

    func load(query: KeychainQuery) throws -> String? {
        storage[key(for: query)]
    }

    func save(query: KeychainQuery, value: String) throws {
        storage[key(for: query)] = value
    }

    func delete(query: KeychainQuery) throws {
        storage.removeValue(forKey: key(for: query))
    }
}
