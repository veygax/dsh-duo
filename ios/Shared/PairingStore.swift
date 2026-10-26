import Foundation
import Security

/// One paired dsh Host, as encoded in its `dshduo://pair` link.
nonisolated struct Pairing: Codable, Equatable, Sendable {
    var relay: URL
    var roomId: String
    /// base64url of the 32-byte room secret.
    var secret: String
    var hostName: String
    /// This install's stable relay identity.
    var deviceId: String

    var crypto: DuoCrypto? {
        Data(base64URL: secret).map(DuoCrypto.init(secret:))
    }

    /// Parse `dshduo://pair?v=1&r=<relay>&i=<room>&k=<secret>&n=<name>`.
    static func parse(_ text: String, deviceId: String) -> Pairing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "dshduo", components.host == "pair" else { return nil }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
        guard let relayText = query["r"], let relay = URL(string: relayText),
              ["http", "https"].contains(relay.scheme ?? ""),
              let room = query["i"], room.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil,
              let secret = query["k"], Data(base64URL: secret)?.count == 32 else { return nil }
        // Accept form-encoded spaces too, as some QR generators emit them.
        let name = (query["n"] ?? "dsh").replacingOccurrences(of: "+", with: " ")
        return Pairing(relay: relay, roomId: room, secret: secret, hostName: name, deviceId: deviceId)
    }
}

/// Keychain storage shared with the Notification Service Extension through a keychain access group.
nonisolated enum PairingStore {
    /// `<team>.<bundle id>.shared`, set per signed build through the `DSHKeychainGroup` Info.plist key.
    /// A team's profiles allow any `<team>.*` group, so signing needs nothing registered on the developer site.
    static let accessGroup = Bundle.main.object(forInfoDictionaryKey: "DSHKeychainGroup") as? String
    private static let service = "ai.deepseek.harness.duo.pairing"
    private static let account = "host"

    private static func query(shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func load() -> Pairing? {
        for shared in [true, false] {
            var request = query(shared: shared)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let pairing = try? JSONDecoder().decode(Pairing.self, from: data) {
                return pairing
            }
        }
        return nil
    }

    @discardableResult
    static func save(_ pairing: Pairing) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        clear()
        for shared in [true, false] {
            var item = query(shared: shared)
            item[kSecValueData as String] = data
            // Readable by the extension while a push arrives on a locked phone.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func clear() {
        SecItemDelete(query(shared: true) as CFDictionary)
        SecItemDelete(query(shared: false) as CFDictionary)
    }

    /// Stable per-install device identity used for relay routing.
    static var deviceId: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "deviceId") { return id }
        let id = "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
        defaults.set(id, forKey: "deviceId")
        return id
    }
}
