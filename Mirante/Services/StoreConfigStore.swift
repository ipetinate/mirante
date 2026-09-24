import Foundation

/// Persists the store configuration. The non-secret fields (owner, repo,
/// branch, publisher identity) live in UserDefaults; the GitHub token is kept
/// in the Keychain via `AuthKeyStore`'s generic-password plumbing, so it never
/// sits in plaintext caches or backups.
enum StoreConfigStore {
    private static let key = "store.config.v1"

    static var config: StoreConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(StoreConfig.self, from: data) else {
                return .empty
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: key)
            }
        }
    }

    /// The GitHub token, handled by the same Keychain code path as the band
    /// auth key but under its own account name.
    private static var tokenStore: AuthKeyStore {
        AuthKeyStore(service: "com.ipetinate.Mirante", account: "github-token")
    }

    static var token: String? {
        tokenStore.key
    }

    @discardableResult
    static func setToken(_ value: String) -> Bool {
        // A token may be any non-blank string; empty clears it.
        tokenStore.setKey(value)
    }

    static func clearToken() {
        tokenStore.clear()
    }

    /// Is the current configuration sufficient to talk to a store?
    static var isConfigured: Bool {
        config.isConfigured
    }
}