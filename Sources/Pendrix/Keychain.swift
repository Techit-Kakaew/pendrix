import Foundation
import Security

/// Minimal generic-password store. Tokens never touch UserDefaults.
enum Keychain {
    private static let service = "dev.techit.pendrix"
    private static let legacyService = "dev.techit.radar"   // pre-rename items are moved on first read

    /// Bumped when the signing identity changes: items get re-created so their ACL names the current app only.
    private static let aclGeneration = "acl-pendrix-dev-1"

    /// Headless runs (--snapshot) never touch the keychain: an unsigned debug binary would trigger a permission dialog.
    nonisolated(unsafe) static var disabled = false

    static func get(_ account: String) -> String? {
        if disabled { return nil }
        if let v = get(account, service: service) { refreshACL(account, v); return v }
        guard let old = get(account, service: legacyService) else { return nil }
        set(old, for: account)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService,
                       kSecAttrAccount as String: account] as CFDictionary)
        return old
    }

    /// Re-create the item once per generation so the ACL is owned by this signed build.
    private static func refreshACL(_ account: String, _ value: String) {
        let key = "\(aclGeneration).\(account)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        set(value, for: account)
        UserDefaults.standard.set(true, forKey: key)
    }

    private static func get(_ account: String, service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        if disabled { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        // Delete + add (not update) so the item's ACL is always the current app, never a stale build.
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var add = base; add[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension Keychain {
    /// Every account stored under our service. Used to re-adopt tokens whose host row was lost.
    static func accounts() -> [String] {
        accounts(service: "dev.techit.pendrix") + accounts(service: "dev.techit.radar")
    }
    private static func accounts(service: String) -> [String] {
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
