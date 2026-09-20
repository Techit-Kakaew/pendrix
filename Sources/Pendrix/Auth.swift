import Foundation
import LocalAuthentication

/// Touch ID (falls back to the account password) in front of settings and write actions.
/// One success covers `grace` seconds so a review session isn't a Touch ID per click.
@MainActor
enum Auth {
    static var grace: TimeInterval = 300
    private static var lastOK: Date?

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func require(_ reason: String) async -> Bool {
        guard Config.shared.requireAuth else { return true }
        if let t = lastOK, Date().timeIntervalSince(t) < grace { return true }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { lastOK = Date() }
            return ok
        } catch { return false }
    }

    static func lock() { lastOK = nil }
}
