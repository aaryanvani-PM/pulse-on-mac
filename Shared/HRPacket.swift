import Foundation

/// Wire protocol between the watch and the Mac (HTTP POST bodies, JSON).
///
///   POST /pair   PairRequest                       -> 200 PairResponse | 403
///   POST /event  SealedPacket (encrypted WatchPacket) -> 204 | 401 | 409
enum PacketEvent {
    /// A fresh heart-rate reading. `bpm` and `sampleTs` are set.
    static let heartRate = "hr"
    /// Session is running but no fresh sample has arrived from the sensor.
    static let missing = "missing"
}

struct WatchPacket: Codable, Sendable {
    /// Which mechanism produced the packet. The Mac picks staleness
    /// semantics from it: `.live` = continuous session (6 s / 15 s windows),
    /// `.passive` = Apple's background sampling, where minutes between
    /// readings are normal. Absent = `.live` (pre-mode watch builds).
    enum Mode: String, Codable, Sendable {
        case live
        case passive
    }

    /// `followUp` = sent from the wake watchOS grants when a previous
    /// background upload finishes (a newer sample was already waiting).
    enum SyncTrigger: String, Codable, Sendable { case foreground, observer, scheduledRefresh, followUp }
    enum AppState: String, Codable, Sendable { case active, inactive, background }

    let event: String
    var bpm: Int?
    /// HealthKit's own sample timestamp (seconds since 1970). The watch never
    /// fabricates a time; the Mac uses it for display and staleness math.
    var sampleTs: TimeInterval?
    var mode: Mode?
    var trigger: SyncTrigger?
    var appState: AppState?
    /// Trace-only: short operation id linking this packet to the Watch's
    /// local trace, and when the Watch handed the packet to the network
    /// layer (seconds since 1970). Neither affects ingest decisions.
    var op: String?
    var queuedTs: TimeInterval?
    /// Earlier readings HealthKit saved since the last confirmed delivery,
    /// each with its own measurement time. `bpm`/`sampleTs` stay the newest
    /// reading; these only fill the Mac's trend history.
    var history: [HistoryPoint]?

    struct HistoryPoint: Codable, Sendable {
        let t: TimeInterval
        let b: Int
    }
}

/// Pairing (see SecureChannel). The code itself is never sent.
struct PairRequest: Codable, Sendable {
    let v: Int
    /// The Watch's X25519 public key, base64.
    let key: String
    /// HMAC proving the Watch was given the pairing code.
    let proof: String
}
struct PairResponse: Codable, Sendable {
    /// The Mac's X25519 public key, base64.
    let key: String
    /// Proof that the Mac derived the same shared secret.
    let confirm: String
    /// The Mac's stable mDNS hostname (e.g. "My-Mac.local"), when known.
    /// The watch prefers it over the IP so DHCP renewals don't break the link.
    var host: String?
}
