import Foundation
import Security

/// Mac-side credentials: the 6-digit pairing code shown to the user and the
/// set of tokens issued to paired watches. Tokens persist in the Keychain so
/// a Mac restart keeps existing pairings valid.
///
/// DEVELOPMENT LIMITATION: pairing and streaming run over plaintext HTTP on
/// the local network. The token is returned once in the /pair response body.
/// This is a local development convenience, NOT production security. See README.
final class MacCredentials: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aryanvani.hrlink.credentials")
    private var tokens: Set<String> = []
    private static let tokenAccount = "mac-paired-tokens"
    private static let cloudTokenAccount = "mac-cloud-token"
    private var cloudTokenValue: String

    /// Access key published to the user's private iCloud database so their
    /// Watch pairs without typing. Stable across launches.
    var cloudToken: String { queue.sync { cloudTokenValue } }

    private var codeValue: String
    private var failedPairAttempts = 0

    /// Part of the pairing number shown in the menu bar window. New on every
    /// launch, and replaced after five wrong attempts so a short code cannot
    /// be guessed by trying them all.
    var pairingCode: String { queue.sync { codeValue } }

    init() {
        codeValue = Self.randomDigits(PairingNumber.codeLength)
        if let data = KeychainStore.load(account: Self.cloudTokenAccount),
           let saved = String(data: data, encoding: .utf8), saved.count == 64 {
            cloudTokenValue = saved
        } else {
            cloudTokenValue = Self.randomHex(32)
            KeychainStore.save(Data(cloudTokenValue.utf8), account: Self.cloudTokenAccount)
        }
        if let data = KeychainStore.load(account: Self.tokenAccount),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            tokens = Set(stored)
        }
    }

    /// Validates a pairing code and issues a new session token. Returns nil
    /// when the code is wrong.
    func verifyPairing(code: String) -> String? {
        queue.sync {
            guard code == codeValue else {
                failedPairAttempts += 1
                if failedPairAttempts >= 5 {
                    failedPairAttempts = 0
                    codeValue = Self.randomDigits(PairingNumber.codeLength)
                }
                return nil
            }
            failedPairAttempts = 0
            let token = Self.randomHex(32)
            tokens.insert(token)
            persistLocked()
            return token
        }
    }

    func isAuthorized(_ token: String) -> Bool {
        queue.sync { !token.isEmpty && (tokens.contains(token) || token == cloudTokenValue) }
    }

    /// Answer to a Watch's "are you my Mac?" challenge, or nil when no key
    /// held here matches the key id. The key itself is never transmitted.
    func proof(keyID: String, nonce: String) -> String? {
        queue.sync {
            guard PairingProof.isValidNonce(nonce) else { return nil }
            for token in tokens.union([cloudTokenValue]) where PairingProof.keyID(for: token) == keyID {
                return PairingProof.proof(token: token, nonce: nonce)
            }
            return nil
        }
    }

    /// Revokes every paired watch (menu-bar "Forget Watch" control).
    func forgetAll() {
        queue.sync {
            tokens.removeAll()
            persistLocked()
            // Rotate the iCloud key as well; the publisher uploads the new
            // one and the Watch picks it up on its next failed send.
            cloudTokenValue = Self.randomHex(32)
            KeychainStore.save(Data(cloudTokenValue.utf8), account: Self.cloudTokenAccount)
        }
    }

    private func persistLocked() {
        if tokens.isEmpty {
            KeychainStore.delete(account: Self.tokenAccount)
        } else if let data = try? JSONEncoder().encode(Array(tokens)) {
            KeychainStore.save(data, account: Self.tokenAccount)
        }
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomDigits(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String($0 % 10) }.joined()
    }
}
