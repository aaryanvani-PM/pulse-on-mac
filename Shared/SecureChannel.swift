import CryptoKit
import Foundation

/// End-to-end protection between the Watch and the Mac.
///
/// Pairing: each side makes a fresh X25519 key pair and they agree on a
/// shared secret, so the secret itself never travels. The Watch proves it
/// knows the 4-digit code with an HMAC instead of sending the code, and the
/// Mac proves it derived the same secret before the Watch stores it.
///
/// Readings: every packet is sealed with AES-GCM (encrypted and tamper-
/// proof). The Mac finds the key by a short, non-secret key id, and refuses
/// packets that are stale or seen before (see `ReplayGuard`).
///
/// Not covered: someone actively intercepting the few seconds of pairing
/// could try every 4-digit code against what they captured. Passive
/// listening at any time learns nothing.
enum SecureChannel {
    static let version = 2

    enum Failure: Error { case badKey, badBox, wrongConfirmation }

    // MARK: Pairing

    static func newKeyPair() -> Curve25519.KeyAgreement.PrivateKey { .init() }

    /// Proof that the Watch was given the pairing code, bound to its key.
    static func codeProof(code: String, watchKey: Data) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data("pulse-pair-code|\(code)".utf8)))
        return hex(HMAC<SHA256>.authenticationCode(for: watchKey, using: key))
    }

    /// The shared secret both sides store (64 hex characters). Never sent.
    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data,
                             watchKey: Data, macKey: Data, code: String) throws -> String {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey) else { throw Failure.badKey }
        let agreed = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let derived = agreed.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                     salt: Data("pulse-on-mac pairing v2".utf8),
                                                     sharedInfo: watchKey + macKey + Data(code.utf8),
                                                     outputByteCount: 32)
        return derived.withUnsafeBytes { hex(Data($0)) }
    }

    /// The Mac's proof that it derived the same secret.
    static func confirmation(secret: String, macKey: Data) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: Data("mac-confirm".utf8) + macKey,
                                            using: SymmetricKey(data: Data(secret.utf8))))
    }

    // MARK: Readings

    /// What is encrypted: the packet plus when it was sealed.
    struct Envelope: Codable { let sent: TimeInterval; let packet: WatchPacket }

    static func seal(_ packet: WatchPacket, secret: String, now: Date = Date()) throws -> SealedPacket {
        let keyID = PairingProof.keyID(for: secret)
        let plain = try JSONEncoder().encode(Envelope(sent: now.timeIntervalSince1970, packet: packet))
        let box = try AES.GCM.seal(plain, using: encryptionKey(secret), authenticating: Data(keyID.utf8))
        guard let combined = box.combined else { throw Failure.badBox }
        return SealedPacket(v: version, k: keyID, box: combined.base64EncodedString())
    }

    /// Decrypts and checks integrity. Returns the packet, when it was sealed,
    /// and the box's nonce (unique per packet, for replay checks).
    static func open(_ sealed: SealedPacket, secret: String) throws -> (packet: WatchPacket, sent: Date, nonce: Data) {
        guard let data = Data(base64Encoded: sealed.box),
              let box = try? AES.GCM.SealedBox(combined: data) else { throw Failure.badBox }
        let plain = try AES.GCM.open(box, using: encryptionKey(secret), authenticating: Data(sealed.k.utf8))
        let envelope = try JSONDecoder().decode(Envelope.self, from: plain)
        return (envelope.packet, Date(timeIntervalSince1970: envelope.sent), Data(box.nonce))
    }

    private static func encryptionKey(_ secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                               info: Data("pulse-on-mac readings v2".utf8), outputByteCount: 32)
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Wire format of an encrypted reading (POST /event body).
struct SealedPacket: Codable, Sendable {
    let v: Int
    /// Key id: which pairing sealed it. Not secret.
    let k: String
    /// AES-GCM combined box, base64.
    let box: String
}

/// Rejects packets sealed too long ago (or too far ahead, for clock skew)
/// and packets already accepted, so a recorded packet can't be played back.
struct ReplayGuard {
    static let window: TimeInterval = 20 * 60
    private var seen: [Data: Date] = [:]

    mutating func accept(nonce: Data, sent: Date, now: Date = Date()) -> Bool {
        guard abs(now.timeIntervalSince(sent)) <= Self.window else { return false }
        seen = seen.filter { now.timeIntervalSince($0.value) <= Self.window * 2 }
        guard seen[nonce] == nil else { return false }
        seen[nonce] = now
        return true
    }
}
