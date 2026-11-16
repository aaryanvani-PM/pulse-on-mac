import Foundation

/// Reads the Mac's current address and access key from the user's private
/// iCloud database: first-time pairing without typing, and recovery when the
/// Mac's address or key has changed.
@MainActor
enum CloudRepair {
    private static var lastAttempt = Date.distantPast
    private static var running = false

    /// Returns true when the stored pairing was created or changed.
    @discardableResult
    static func attempt(reason: String, minimumInterval: TimeInterval = 60) async -> Bool {
        guard CloudPairing.isEnabled, !running, Date().timeIntervalSince(lastAttempt) >= minimumInterval else { return false }
        running = true
        lastAttempt = Date()
        defer { running = false }
        let started = Date()
        do {
            guard let endpoint = try await CloudPairing.fetch() else {
                PassiveTrace.event("cloud.fetch", ["reason": reason, "result": "no-record"])
                return false
            }
            let ms = String(Int(Date().timeIntervalSince(started) * 1000))
            let current = CredentialStore.current
            if let current, current.token == endpoint.token, current.dialOrder.contains(endpoint.address) {
                PassiveTrace.event("cloud.fetch", ["reason": reason, "result": "unchanged", "ms": ms])
                return false
            }
            CredentialStore.save(WatchCredentials(host: endpoint.address, fallbackHost: endpoint.hostname,
                                                  token: endpoint.token))
            PassiveTrace.event("cloud.fetch", [
                "reason": reason, "ms": ms,
                "result": current == nil ? "paired" : (current?.token == endpoint.token ? "address-updated" : "key-updated"),
            ])
            return true
        } catch {
            let nsError = error as NSError
            PassiveTrace.event("cloud.fetch", ["reason": reason, "result": "error",
                                               "error": "\(nsError.domain) \(nsError.code)"])
            return false
        }
    }
}
