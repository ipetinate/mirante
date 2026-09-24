import Foundation
import Security

/// Stores and validates the band's auth key: the 32-hex pairing secret used in
/// the Mili handshake. It lives in the Keychain so it never sits in plaintext
/// in UserDefaults or app backups. If the user never provides a key, Mirante
/// stays in create/share mode and never attempts an install.
struct AuthKeyStore {
    let service: String
    let account: String

    init(service: String = "com.ipetinate.Mirante", account: String = "band-auth-key") {
        self.service = service
        self.account = account
    }

    var key: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setKey(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// A valid auth key is exactly 32 hexadecimal characters, either case.
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 32 else { return false }
        return trimmed.unicodeScalars.allSatisfy(CharacterSet.hexSet.contains)
    }

    /// Trims whitespace and normalizes to lowercase zero-padded hex.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension CharacterSet {
    /// The ASCII hex characters in both cases.
    static let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
}