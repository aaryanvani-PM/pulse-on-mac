import Foundation
import Security

/// Mac-side credentials: the pairing code shown to the user and the shared
/// secrets agreed with paired watches (see SecureChannel). Secrets are
/// derived on both sides and never sent; they persist in the Keychain so a
/// Mac restart keeps pairings valid.
final class MacCredentials: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aryanvani.hrlink.credentials")
    private var tokens: Set<String> = []
    private static let tokenAccount = "mac-paired-keys-v2"
    /// Pre-encryption pairings: their keys crossed the network, so they are
    /// dropped and the Watch pairs again.
    private static let legacyTokenAccount = "mac-paired-tokens"
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
        KeychainStore.delete(account: Self.legacyTokenAccount)
        if let data = KeychainStore.load(account: Self.tokenAccount),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            tokens = Set(stored)
        }
    }

    /// Checks the Watch's proof of the pairing code, agrees a shared secret
    /// with it and returns the reply. Nil when the proof is wrong.
    func pair(_ request: PairRequest) -> (response: PairResponse, secret: String)? {
        queue.sync {
            guard request.v == SecureChannel.version, let watchKey = Data(base64Encoded: request.key),
                  request.proof == SecureChannel.codeProof(code: codeValue, watchKey: watchKey) else {
                failedPairAttempts += 1
                if failedPairAttempts >= 5 {
                    failedPairAttempts = 0
                    codeValue = Self.randomDigits(PairingNumber.codeLength)
                }
                return nil
            }
            failedPairAttempts = 0
            let privateKey = SecureChannel.newKeyPair()
            let macKey = privateKey.publicKey.rawRepresentation
            guard let secret = try? SecureChannel.sharedSecret(privateKey: privateKey, peerKey: watchKey,
                                                               watchKey: watchKey, macKey: macKey, code: codeValue)
            else { return nil }
            tokens.insert(secret)
            persistLocked()
            let response = PairResponse(key: macKey.base64EncodedString(),
                                        confirm: SecureChannel.confirmation(secret: secret, macKey: macKey),
                                        host: LocalAddress.localHostname())
            return (response, secret)
        }
    }

    var hasPairedWatch: Bool { queue.sync { !tokens.isEmpty } }

    /// The shared secret for a packet's key id, if that Watch is paired.
    func secret(forKeyID keyID: String) -> String? {
        queue.sync {
            tokens.union([cloudTokenValue]).first { PairingProof.keyID(for: $0) == keyID }
        }
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
