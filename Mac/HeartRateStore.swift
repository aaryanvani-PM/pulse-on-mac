import Foundation
import Observation

/// UI state for the menu-bar window. Everything is derived, nothing inferred:
/// live-mode staleness is judged on receive time (immune to watch clock skew),
/// while PASSIVE staleness is judged on HealthKit's own sample timestamp — a
/// resent old reading must not pose as fresh. The displayed "reading time" is
/// the sample timestamp; "received" is kept alongside so both ages are visible.
@MainActor
@Observable
final class HeartRateStore {
    struct Sample: Identifiable, Equatable {
        let id = UUID()
        let bpm: Int
        /// When HealthKit recorded the reading on the watch.
        let recordedAt: Date
        /// When this Mac received it.
        let receivedAt: Date
        /// Which mechanism delivered it — this decides the staleness rules.
        let mode: WatchPacket.Mode
    }

    enum Status: Equatable {
        case off
        case failed(String)
        case needsLocalNetworkPermission(String)
        case waiting
        case connected
        case live
        case stale
        /// Latest sample came from passive background sync: a sparse cadence
        /// is expected and healthy, not an error.
        case passiveSynced
        /// Passive sync, but nothing from Apple for a while (typically the
        /// watch is off wrist or not being worn).
        case passiveQuiet
    }

    /// A live-mode reading received within this window is "live".
    /// During a session the Watch sends only when HealthKit produces a new
    /// reading, which happens every 1–10 s, not on a fixed beat. A shorter
    /// window made the status flicker Live → Connected between readings.
    /// 15 s matches the Watch's own "no new reading" threshold, after which
    /// it reports the sensor as missing.
    static let freshWindow: TimeInterval = 15
    /// A live sample whose MEASUREMENT is older than this cannot pose as
    /// live even if its packet just arrived (delayed delivery / replay).
    static let liveSampleWindow: TimeInterval = 15
    /// Any authorized traffic within this window keeps "connected".
    static let connectedWindow: TimeInterval = 15
    /// A passive reading received within this window counts as "synced".
    /// Apple's rest cadence is a sample every few minutes; anything beyond
    /// 20 minutes means genuinely no readings (off wrist, etc).
    static let passiveWindow: TimeInterval = 20 * 60
    static let maxSamples = 600

    private(set) var serverState: ServerState = .stopped
    private(set) var samples: [Sample] = []
    private(set) var lastEventText: String?
    private(set) var lastDeliveryText: String?
    private(set) var lastBackgroundDeliveryAt: Date?
    /// NEW measurements (not duplicates) that arrived from a background
    /// wake since this app launched, and the newest such measurement time.
    private(set) var backgroundReadingsAccepted = 0
    private(set) var lastBackgroundReadingAt: Date?
    /// Every authorized packet and what was decided, for the ingest log.
    /// Active (1 Hz) traffic is left out by the app to keep the log small.
    var onDecision: ((WatchPacket, String, Date) -> Void)?
    /// Long-running history behind the trend chart (persisted by the app).
    let trend: TrendHistory
    private var lastLiveTrendAt: TimeInterval = 0
    private(set) var pairingCode = ""
    private(set) var localAddress: String?
    private var lastTrafficAt: Date?
    /// Last authenticated message from a paired Watch (a reading or a
    /// successful pairing), and the Mac's address at that moment. Saved, so
    /// connection health survives a relaunch.
    private(set) var lastContactAt: Date?
    private(set) var contactAddress: String?
    /// Last time a Watch sent something this Mac couldn't open (out-of-date
    /// pairing). Cleared by the next good contact.
    private(set) var lastRejectedAt: Date?
    @ObservationIgnored private let contactDefaults: UserDefaults?
    @ObservationIgnored private var contactSavedAt = Date.distantPast

    /// 1 Hz heartbeat. Time-derived UI (the menu-bar label, live→stale
    /// fades, passive-sync age) observes this so it re-renders every second
    /// even when no traffic arrives.
    private(set) var now = Date()

    var currentBPM: Int? { samples.last?.bpm }

    var serverIsRunning: Bool {
        switch serverState {
        case .listening, .waitingPermission: return true
        default: return false
        }
    }

    init(historyURL: URL? = nil) {
        trend = TrendHistory(url: historyURL)
        // Only the real app (which saves history) remembers contact times.
        contactDefaults = historyURL == nil ? nil : .standard
        if let defaults = contactDefaults, defaults.double(forKey: "lastContactAt") > 0 {
            lastContactAt = Date(timeIntervalSince1970: defaults.double(forKey: "lastContactAt"))
            contactAddress = defaults.string(forKey: "contactAddress")
        }
        // After a relaunch, show the last known reading with its true age
        // instead of an empty menu bar.
        if let last = trend.points.last {
            samples = [Sample(bpm: last.bpm, recordedAt: last.date, receivedAt: last.date, mode: .passive)]
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    func status(at now: Date) -> Status {
        switch serverState {
        case .stopped:
            return .off
        case .failed(let message):
            return .failed(message)
        case .waitingPermission(let message):
            return .needsLocalNetworkPermission(message)
        case .listening:
            guard let last = samples.last else {
                if let lastTraffic = lastTrafficAt, now.timeIntervalSince(lastTraffic) < Self.connectedWindow {
                    return .connected
                }
                return .waiting
            }
            switch last.mode {
            case .live:
                // "Live" requires BOTH delivery continuity (packet just
                // arrived) and measurement recency (the sample itself is
                // fresh): a delayed or replayed old packet must not pose
                // as live. Clock skew clamps the measurement age at 0.
                let measurementAge = max(0, now.timeIntervalSince(last.recordedAt))
                if now.timeIntervalSince(last.receivedAt) < Self.freshWindow,
                   measurementAge < Self.liveSampleWindow {
                    return .live
                }
                if let lastTraffic = lastTrafficAt, now.timeIntervalSince(lastTraffic) < Self.connectedWindow {
                    return .connected
                }
                return .stale
            case .passive:
                // Judge on MEASUREMENT age, not arrival: the watch re-sends
                // its newest known sample on foreground opens, so receive
                // time would let an hours-old reading pose as freshly
                // synced for another 20-minute window. Future timestamps
                // (clock skew) are clamped to zero.
                let measurementAge = max(0, now.timeIntervalSince(last.recordedAt))
                return measurementAge < Self.passiveWindow ? .passiveSynced : .passiveQuiet
            }
        }
    }

    func configure(pairingCode: String, localAddress: String?) {
        self.pairingCode = pairingCode
        self.localAddress = localAddress
    }

    /// Called from the window's 1-second tick: the Mac's DHCP address can
    /// change while the app runs, and a stale address breaks pairing.
    func refreshLocalAddress(_ address: String?) {
        if localAddress != address {
            localAddress = address
        }
    }

    /// The code is replaced after repeated wrong attempts; keep the UI current.
    func refreshPairingCode(_ code: String) {
        if pairingCode != code { pairingCode = code }
    }

    /// The single number typed on the Watch, or nil without a usable address.
    var pairingNumber: String? {
        guard let localAddress else { return nil }
        return PairingNumber.encode(address: localAddress, code: pairingCode)
    }

    func setServerState(_ state: ServerState) {
        serverState = state
    }

    func ingest(_ packet: WatchPacket) {
        let decision = decide(packet)
        onDecision?(packet, decision, Date())
    }

    private func decide(_ packet: WatchPacket) -> String {
        lastTrafficAt = Date()
        noteContact()
        if let trigger = packet.trigger, let state = packet.appState {
            lastDeliveryText = "\(trigger.rawValue) · watch \(state.rawValue)"
            if state == .background, trigger != .foreground {
                lastBackgroundDeliveryAt = Date()
            }
        }
        switch packet.event {
        case PacketEvent.heartRate:
            // Trust-boundary validation: physiologically plausible BPM.
            // A heart-rate reading WITHOUT its measurement timestamp is
            // rejected outright — substituting "now" would let an undated
            // reading pose as fresh forever. (Live and passive senders
            // always carry sampleTs; only "missing" events omit it, and
            // those never reach this branch.)
            guard let bpm = packet.bpm, (20...250).contains(bpm),
                  let ts = packet.sampleTs
            else { return "rejected-invalid" }
            let recordedAt = Date(timeIntervalSince1970: ts)
            if let history = packet.history {
                // Backfilled readings keep their own measurement times and
                // never touch the "current" value.
                let horizon = Date().timeIntervalSince1970
                trend.insert(history.compactMap {
                    guard (20...250).contains($0.b), $0.t <= horizon + 60, $0.t >= horizon - 8 * 86400 else { return nil }
                    return TrendPoint(t: $0.t, bpm: $0.b)
                })
            }
            guard recordedAt <= Date().addingTimeInterval(60),
                  recordedAt >= Date().addingTimeInterval(-365 * 86400)
            else { return "rejected-timestamp-range" }
            // Monotonic ingest: an out-of-order (older) reading must not
            // replace a newer one and move the displayed BPM backward.
            // Equal timestamps are duplicate deliveries (e.g. catch-up
            // resends of the same sample) — dropped as well.
            if let lastSample = samples.last, recordedAt <= lastSample.recordedAt {
                return recordedAt == lastSample.recordedAt ? "duplicate" : "older-than-shown"
            }
            samples.append(
                Sample(
                    bpm: bpm,
                    recordedAt: recordedAt,
                    receivedAt: Date(),
                    mode: packet.mode ?? .live
                )
            )
            if samples.count > Self.maxSamples {
                samples.removeFirst(samples.count - Self.maxSamples)
            }
            // Passive readings are sparse: keep all. A live session sends
            // about one a second: keep one every 10 s for the trend.
            if packet.mode == .passive || ts - lastLiveTrendAt >= 10 {
                trend.insert([TrendPoint(t: ts, bpm: bpm)])
                if packet.mode != .passive { lastLiveTrendAt = ts }
            }
            if packet.appState == .background, let trigger = packet.trigger, trigger != .foreground {
                backgroundReadingsAccepted += 1
                lastBackgroundReadingAt = recordedAt
            }
            return "accepted"
        case PacketEvent.missing:
            lastEventText = "Session is running, but no fresh sensor reading has arrived."
            return "missing-notice"
        default:
            return "ignored-event"
        }
    }

    func notePairing(_ result: PairResult) {
        lastTrafficAt = Date()
        switch result {
        case .success:
            noteContact()
            lastEventText = "A watch paired successfully."
        case .badCode:
            lastEventText = "A watch tried to pair with a wrong code."
        case .failure(let message):
            lastEventText = message
        }
    }

    /// A Watch reached this Mac and proved it's paired.
    private func noteContact() {
        let now = Date()
        lastContactAt = now
        contactAddress = localAddress
        lastRejectedAt = nil
        // Live sessions send every few seconds; save at most twice a minute.
        guard let defaults = contactDefaults, now.timeIntervalSince(contactSavedAt) > 30 else { return }
        contactSavedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: "lastContactAt")
        defaults.set(localAddress, forKey: "contactAddress")
    }

    /// A Watch sent a reading this Mac couldn't open.
    func noteRejected() { lastRejectedAt = Date() }

    func notePairingCleared() {
        lastEventText = "Pairing cleared. Re-pair your watch to stream again."
    }

    /// Compact age for display: "just now", "45s ago", "4m ago", "1h 07m ago".
    nonisolated static func ageText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 20 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h \(minutes % 60)m ago"
    }

    /// The same age, worded for VoiceOver ("5m" would be read as metres).
    nonisolated static func spokenAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        return hours == 1 ? "about 1 hour ago" : "about \(hours) hours ago"
    }
}
