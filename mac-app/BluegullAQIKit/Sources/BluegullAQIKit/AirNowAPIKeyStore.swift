/// Reads, writes, and deletes the user's own AirNow API key (Direct mode --
/// see doc/DESIGN.md "Data-source modes") as an iCloud-synced Keychain item,
/// so it follows the user across their Macs under their Apple ID
/// (bluegull-aqi-10h.5). NOT the backend service's own key, which lives in
/// AWS SSM and never reaches this app.
public struct AirNowAPIKeyStore: Sendable {
    private static let query = KeychainQuery(
        // Not necessarily the app's bundle ID (Keychain doesn't require
        // that) -- revisit once bluegull-aqi-8ef.5 settles on the real one,
        // for consistency if nothing else.
        service: "org.bluegull.aqi.airnow-api-key",
        account: "airnow-api-key"
    )

    private let keychain: KeychainStore

    public init(keychain: KeychainStore = SystemKeychain()) {
        self.keychain = keychain
    }

    /// nil if no key has been saved yet -- not an error state (e.g. a fresh
    /// install in Service mode, which needs no key at all).
    public func load() throws -> String? {
        try keychain.load(query: Self.query)
    }

    public func save(_ apiKey: String) throws {
        try keychain.save(query: Self.query, value: apiKey)
    }

    public func delete() throws {
        try keychain.delete(query: Self.query)
    }
}
