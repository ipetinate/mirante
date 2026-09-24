import Foundation

/// Holds the app's single store configuration. There is no on-device setup:
/// the store is always `ipetinate/mirante-store`. The GitHub token is kept in
/// the Keychain via `AuthKeyStore`'s generic-password plumbing, with a
/// gitignored `LocalStoreToken` bootstrap used only when a Keychain token
/// hasn't been written yet — so the store works (browse + publish) out of the
/// box using the account that generated the token.
enum StoreConfigStore {
    /// The one and only store the app talks to.
    static var config: StoreConfig {
        .standard
    }

    /// The GitHub token: explicit Keychain entry wins, otherwise the local
    /// dev bootstrap (which can later be promoted to the Keychain).
    private static var tokenStore: AuthKeyStore {
        AuthKeyStore(service: "com.ipetinate.Mirante", account: "github-token")
    }

    static var token: String? {
        if let keychain = tokenStore.key, !keychain.isEmpty { return keychain }
        return LocalStoreToken.value
    }

    @discardableResult
    static func setToken(_ value: String) -> Bool {
        // A token may be any non-blank string; empty clears it.
        tokenStore.setKey(value)
    }

    static func clearToken() {
        tokenStore.clear()
    }

    /// The store is always configured; no gates anywhere.
    static var isConfigured: Bool {
        true
    }
}