import Foundation
import Security

/// All secrets live in ONE generic-password item ("vault", JSON dict). One item = at most one
/// permission prompt when the app's signature changes, instead of one per token.
enum Keychain {
    private static let service = "dev.techit.pendrix"
    private static let vaultAccount = "vault"
    private static let legacyService = "dev.techit.radar"
    private static let legacyAccounts = ["jiraToken", "anthropicKey"]

    /// Headless runs (--snapshot) never touch the keychain: an unsigned debug binary would trigger a permission dialog.
    nonisolated(unsafe) static var disabled = false

    private static var cache: [String: String]?

    static func get(_ account: String) -> String? {
        if disabled { return nil }
        return vault()[account]
    }

    static func set(_ value: String, for account: String) {
        if disabled { return }
        var v = vault()
        if value.isEmpty { v.removeValue(forKey: account) } else { v[account] = value }
        write(v)
    }

    static func accounts() -> [String] { disabled ? [] : Array(vault().keys) }

    // MARK: vault

    private static func vault() -> [String: String] {
        if let c = cache { return c }
        var v: [String: String] = [:]
        if let data = read(account: vaultAccount, service: service),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] { v = d }
        if v.isEmpty { v = migrate(); if !v.isEmpty { write(v) } }
        cache = v
        return v
    }

    private static func write(_ v: [String: String]) {
        cache = v
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: vaultAccount]
        // Delete + add (not update) so the item's ACL is always the current app, never a stale build.
        SecItemDelete(base as CFDictionary)
        guard !v.isEmpty, let data = try? JSONSerialization.data(withJSONObject: v) else { return }
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// One-time: gather the per-token items from 0.1/0.2 (both services) into the vault and delete them.
    private static func migrate() -> [String: String] {
        var out: [String: String] = [:]
        for svc in [service, legacyService] {
            for acct in listAccounts(service: svc) where acct != vaultAccount {
                if let d = read(account: acct, service: svc), let s = String(data: d, encoding: .utf8), !s.isEmpty { out[acct] = s }
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc,
                               kSecAttrAccount as String: acct] as CFDictionary)
            }
        }
        return out
    }

    private static func read(account: String, service: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func listAccounts(service: String) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
