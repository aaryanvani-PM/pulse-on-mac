import CryptoKit
import Foundation

/// Lets the Watch recognise its own Mac without ever sending the access key
/// to an unknown device: the Watch sends a random challenge and a short,
/// non-secret key id; only a Mac holding the key can compute the answer.
enum PairingProof {
    static func keyID(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func proof(token: String, nonce: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.count == 32 && nonce.allSatisfy(\.isHexDigit)
    }
}

struct HelloResponse: Codable, Sendable { let proof: String }
