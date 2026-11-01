import Foundation
import Security
import CryptoKit

/// Generic-password Keychain storage, this device only, available after first unlock.
enum Keychain {
    private static let service = "eu.appinsource.servermonitor"

    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func setString(_ s: String, for key: String) { set(Data(s.utf8), for: key) }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ key: String) -> String? { get(key).flatMap { String(data: $0, encoding: .utf8) } }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Per-server secrets and the app's own SSH identity.
enum Credentials {
    static func passwordKey(_ id: UUID) -> String { "server.\(id).password" }
    static func privateKeyKey(_ id: UUID) -> String { "server.\(id).privatekey" }
    static func passphraseKey(_ id: UUID) -> String { "server.\(id).passphrase" }
    static func hostKeyKey(_ id: UUID) -> String { "server.\(id).hostkey" }

    static func removeAll(for id: UUID) {
        [passwordKey(id), privateKeyKey(id), passphraseKey(id), hostKeyKey(id)].forEach(Keychain.delete)
    }
}

/// One ed25519 key generated on this iPhone. Its public half is added to
/// authorized_keys during setup, so the root password is not kept.
enum AppIdentity {
    private static let key = "app.ed25519"

    static var privateKey: Curve25519.Signing.PrivateKey {
        if let raw = Keychain.get(key), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return k
        }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(k.rawRepresentation, for: key)
        return k
    }

    /// "ssh-ed25519 AAAA… comment"
    static var publicKeyLine: String {
        let pub = privateKey.publicKey.rawRepresentation
        var blob = Data()
        func put(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            blob.append(Data(bytes: &len, count: 4))
            blob.append(d)
        }
        put(Data("ssh-ed25519".utf8))
        put(pub)
        return "ssh-ed25519 \(blob.base64EncodedString()) server-monitor-ios"
    }

    static var fingerprint: String {
        let parts = publicKeyLine.split(separator: " ")
        guard parts.count > 1, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Settings for push (APNs .p8 key is a secret → Keychain).
enum PushSettings {
    static var keyP8: String? {
        get { Keychain.string("apns.p8") }
        set { if let v = newValue { Keychain.setString(v, for: "apns.p8") } else { Keychain.delete("apns.p8") } }
    }
    static var keyID: String {
        get { UserDefaults.standard.string(forKey: "apns.keyID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "apns.keyID") }
    }
    static var teamID: String {
        get { UserDefaults.standard.string(forKey: "apns.teamID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "apns.teamID") }
    }
    static var configured: Bool { keyP8 != nil && keyID.count == 10 && teamID.count == 10 }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
}
