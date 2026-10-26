import CryptoKit
import Foundation

/// End-to-end sealing shared with the dsh plugin (docs/PROTOCOL.md §2).
nonisolated struct DuoCrypto: Sendable {
    private static let salt = Data("dsh-duo".utf8)
    private static let aad = Data("dsh-duo/v1".utf8)

    let key: SymmetricKey
    /// Room credential presented to the relay, lowercase hex.
    let relayAuth: String

    init(secret: Data) {
        let master = SymmetricKey(data: secret)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Self.salt, info: Data("e2e-v1".utf8), outputByteCount: 32)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Self.salt, info: Data("relay-auth".utf8), outputByteCount: 32)
        relayAuth = auth.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// base64(nonce ‖ ciphertext ‖ tag)
    func seal(_ data: Data) throws -> String {
        try AES.GCM.seal(data, using: key, authenticating: Self.aad).combined!.base64EncodedString()
    }

    func seal(json object: Any) throws -> String {
        try seal(JSONSerialization.data(withJSONObject: object))
    }

    func open(_ sealed: String) -> Data? {
        guard let raw = Data(base64Encoded: sealed), raw.count >= 28,
              let box = try? AES.GCM.SealedBox(combined: raw) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Self.aad)
    }
}

extension Data {
    nonisolated init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        self.init(base64Encoded: text)
    }
}
