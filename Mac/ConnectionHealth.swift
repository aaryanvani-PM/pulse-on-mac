import Foundation
import Observation

/// How the Watch–Mac link looks from the Mac. The Mac can't contact the
/// Watch (watchOS apps can't accept connections), so this is judged from
/// what the Mac can check itself plus how recently the Watch checked in.
/// Green: fine. Yellow: probably fine, worth a look. Red: needs fixing.
struct ConnectionHealth: Equatable {
    enum Level { case good, warning, problem }

    let level: Level
    /// One or two words beside the dot.
    let word: String
    /// What's going on, for the info popover.
    let detail: String
    /// What to do about it, if anything.
    let fix: String?

    /// No check-in for this long turns the dot yellow. Background readings
    /// come about every 15 minutes while the Watch is worn.
    static let quietAfter: TimeInterval = 20 * 60

    static func evaluate(serverState: ServerState, receiverResponding: Bool, hasPairedWatch: Bool,
                         lastContact: Date?, lastRejected: Date?, contactAddress: String?,
                         currentAddress: String?, now: Date) -> ConnectionHealth {
        switch serverState {
        case .stopped:
            return ConnectionHealth(level: .problem, word: "Stopped", detail: "The receiver is stopped, so your Watch can't reach this Mac.",
                                    fix: "Click Start Receiver below.")
        case .failed(let message):
            return ConnectionHealth(level: .problem, word: "Error", detail: "The receiver couldn't start: \(message)",
                                    fix: "Quit Pulse on Mac and open it again.")
        case .waitingPermission:
            return ConnectionHealth(level: .problem, word: "Permission", detail: "macOS is blocking Local Network access, so your Watch can't reach this Mac.",
                                    fix: "Open System Settings > Privacy & Security > Local Network and turn on Pulse on Mac.")
        case .listening:
            break
        }
        if !receiverResponding {
            return ConnectionHealth(level: .problem, word: "Not responding", detail: "The receiver is running but didn't answer its last self-check.",
                                    fix: "Click Stop Receiver, then Start Receiver. If that doesn't help, quit and reopen Pulse on Mac.")
        }
        guard hasPairedWatch else {
            return ConnectionHealth(level: .problem, word: "Not paired", detail: "No Apple Watch is paired with this Mac.",
                                    fix: "Open Pulse on your Watch and enter the pairing number below.")
        }
        if let rejected = lastRejected, rejected > (lastContact ?? .distantPast) {
            return ConnectionHealth(level: .problem, word: "Re-pair", detail: "Your Watch is trying to connect with an old pairing this Mac no longer accepts.",
                                    fix: "On your Watch, open Pulse, scroll down, tap Unpair Mac, then enter the pairing number below.")
        }
        guard let lastContact else {
            return ConnectionHealth(level: .warning, word: "Waiting", detail: "Paired, but your Watch hasn't checked in since this Mac started.",
                                    fix: "Open Pulse on your Watch. It connects as soon as it opens.")
        }
        let ago = HeartRateStore.spokenAge(now.timeIntervalSince(lastContact))
        if let contactAddress, let currentAddress, contactAddress != currentAddress {
            return ConnectionHealth(level: .warning, word: "Address changed",
                                    detail: "This Mac's network address changed since your Watch last connected (\(ago)).",
                                    fix: "Open Pulse on your Watch and keep it on screen for a minute; it looks for this Mac and reconnects. If it can't, tap Unpair Mac and enter the pairing number below.")
        }
        if now.timeIntervalSince(lastContact) > quietAfter {
            return ConnectionHealth(level: .warning, word: "Quiet", detail: "Your Watch last checked in \(ago).",
                                    fix: "This is normal while the Watch is off your wrist or charging. Otherwise check it's on the same Wi‑Fi and the Pulse complication is on your watch face, then open Pulse once.")
        }
        return ConnectionHealth(level: .good, word: "Connected", detail: "Your Watch last checked in \(ago).", fix: nil)
    }
}

/// Checks once a minute that this Mac's receiver actually answers, the one
/// part of the link the Mac can test on its own.
@MainActor
@Observable
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()
    private(set) var receiverResponding = true
    private(set) var lastChecked: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(isListening: @escaping @MainActor () -> Bool) {
        task?.cancel()
        task = Task { [weak self] in
            // Give the listener a moment to come up at launch.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                if isListening() {
                    let ok = await Self.ping()
                    self?.receiverResponding = ok
                } else {
                    self?.receiverResponding = true   // the server state already explains it
                }
                self?.lastChecked = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private static func ping() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:5337/ping")!)
        request.timeoutInterval = 4
        // One retry: a single slow answer shouldn't flip the dot red.
        for _ in 0..<2 {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 204 { return true }
        }
        return false
    }
}
