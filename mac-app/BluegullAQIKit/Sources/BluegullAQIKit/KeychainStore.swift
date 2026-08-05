import Foundation
import Security

/// Identifies a single Keychain item.
/// The Keychain access group shared by the container app and the widget
/// extension (bluegull-aqi-mtm.25), matching the `keychain-access-groups`
/// entitlement both targets declare in `mac-app/project.yml`.
///
/// The team prefix is written out rather than resolved at runtime: it's the
/// literal value `$(AppIdentifierPrefix)` expands to, and it's a public
/// identifier, not a secret -- `project.yml` already carries the same value
/// as `DEVELOPMENT_TEAM` for the same reason.
public enum KeychainAccessGroup {
    public static let shared = "G5DWPBWHQ5.solutions.bluegull.aqi"
}

public struct KeychainQuery: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    /// The item existed but its stored value wasn't decodable as a UTF-8
    /// string.
    case unexpectedData
    /// A Security framework call failed; see
    /// `SecCopyErrorMessageString(status, nil)` for a human-readable reason.
    case osStatus(OSStatus)
}

/// Abstraction over Keychain access (bluegull-aqi-10h.5) so callers are
/// testable without touching the real system keychain. A bare `swift test`
/// process is not a signed, entitled app bundle -- reading/writing the
/// actual macOS Keychain from an automated test would risk leaving real
/// persistent state behind (or failing outright from missing entitlements),
/// so tests inject an in-memory fake instead; only `SystemKeychain` (below)
/// talks to the real thing.
public protocol KeychainStore: Sendable {
    func load(query: KeychainQuery) throws -> String?
    func save(query: KeychainQuery, value: String) throws
    func delete(query: KeychainQuery) throws
}

/// Real Keychain-backed implementation. Items are iCloud-synced
/// (`kSecAttrSynchronizable`) so a key follows the user across their Macs
/// under their Apple ID, per bluegull-aqi-10h.5 -- which requires an
/// accessibility level other than one of the "ThisDeviceOnly" variants
/// (those explicitly opt out of sync); `kSecAttrAccessibleAfterFirstUnlock`
/// is used here, the standard choice for a syncable item an app needs
/// outside of active user interaction.
///
/// Reviewed for bluegull-aqi-10h.13, **revised** for bluegull-aqi-mtm.25:
/// - Accessibility: `kSecAttrAccessibleAfterFirstUnlock`, not `.always` (a
///   deprecated, insecure choice that leaves the item readable even while
///   the device is locked). Correct for a syncable background item.
/// - Sync: `kSecAttrSynchronizable = true`, confirmed.
/// - Access group: `KeychainAccessGroup.shared`, covering the container app
///   and the widget extension. 10h.13 originally concluded no access group
///   was needed, on the premise that "the widget extension only reads
///   pre-fetched AQI data from the App Group cache, never the raw key."
///   That premise ended with bluegull-aqi-mtm.24: the widget now performs
///   its own fetches, so in Direct mode it needs the user's AirNow key like
///   the container app does. Reconsidered deliberately (Steve, 2026-08-05)
///   rather than allowed to slip in -- `ComplianceTests` enforced that.
///
///   The exposure this adds is real and bounded: one additional
///   same-team, same-developer process can read one credential. The
///   sharper risk is not storage but *transmission* -- `AirNowDirectClient`
///   puts the key in a URL query parameter, which CLAUDE.md names as the
///   likeliest leak vector in this project because it looks exactly like
///   ordinary debug logging. That risk now exists in two processes;
///   `ComplianceTests.testNoRequestURLLogging` guards it.
public struct SystemKeychain: KeychainStore {
    public init() {}

    public func load(query: KeychainQuery) throws -> String? {
        var attributes = Self.baseAttributes(for: query)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return value
    }

    public func save(query: KeychainQuery, value: String) throws {
        let data = Data(value.utf8)
        let baseAttributes = Self.baseAttributes(for: query)

        // Update first -- the common case after the item already exists --
        // falling back to add only if it doesn't.
        let updateStatus = SecItemUpdate(
            baseAttributes as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addAttributes = baseAttributes
            addAttributes[kSecValueData as String] = data
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func delete(query: KeychainQuery) throws {
        let status = SecItemDelete(Self.baseAttributes(for: query) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private static func baseAttributes(for query: KeychainQuery) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: query.service,
            kSecAttrAccount as String: query.account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessGroup as String: KeychainAccessGroup.shared,
        ]
    }
}
