import Foundation

/// Watch-side credentials: the Mac hosts it can reach and the bearer token
/// the Mac issued. Persisted in the Keychain, never UserDefaults.
///
/// `host` is preferred (the Mac's .local hostname when known — it survives
/// DHCP renewals); `fallbackHost` is the IP typed at pairing time, used when
/// mDNS resolution fails.
struct WatchCredentials: Codable, Equatable {
    let host: String
    let fallbackHost: String?
    let token: String

    static func baseURL(for host: String) -> String { "http://\(host):5337" }

    /// Dial order: preferred host first, then the fallback.
    var dialOrder: [String] {
        var hosts = [host]
        if let fallbackHost, !fallbackHost.isEmpty, fallbackHost != host {
            hosts.append(fallbackHost)
        }
        return hosts
    }
}

enum CredentialStore {
    private static let account = "watch-mac-credentials"

    static func prepareForBackground() {
        KeychainStore.prepareForBackground(account: account)
    }

    static var current: WatchCredentials? {
        guard let data = KeychainStore.load(account: account) else { return nil }
        return try? JSONDecoder().decode(WatchCredentials.self, from: data)
    }

    static func save(_ credentials: WatchCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        KeychainStore.save(data, account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
    }
}
