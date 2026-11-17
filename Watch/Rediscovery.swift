import Foundation
import WatchKit

/// Finds the paired Mac again after its address changes. A router usually
/// hands out a new address on the same network, so only the last number
/// differs: ask each address there "are you my Mac?" (see PairingProof) and
/// adopt the one that proves it holds our key.
@MainActor
enum Rediscovery {
    static let minimumInterval: TimeInterval = 120
    private static var lastAttempt = Date.distantPast
    private static var running = false

    /// True when the Mac was found at a new address and the pairing updated.
    @discardableResult
    static func attempt(reason: String, force: Bool = false) async -> Bool {
        guard !running, force || Date().timeIntervalSince(lastAttempt) >= minimumInterval else { return false }
        // ~250 short connection attempts: only with the app on screen.
        // (Inactive = app frontmost with the wrist lowered; still has runtime.)
        guard WKApplication.shared().applicationState != .background else { return false }
        guard let credentials = CredentialStore.current,
              let known = credentials.dialOrder.first(where: { PairingNumber.octets(of: $0) != nil }),
              let octets = PairingNumber.octets(of: known) else { return false }
        running = true
        lastAttempt = Date()
        defer { running = false }
        let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"
        // Routers usually hand out addresses from the bottom of the range or
        // from .100 upward, so try those first; most searches end early.
        let likely = Array(2...40) + Array(100...140)
        let order = likely + (1...254).filter { !likely.contains($0) }
        let candidates = order.filter { $0 != octets[3] }.map { "\(prefix).\($0)" }
        PassiveTrace.event("rediscovery.start", ["reason": reason, "candidates": String(candidates.count)])
        let started = Date()
        // Its own task: the caller may be cancelled (a sync timeout, a view
        // going away) and that must not abort a search already under way.
        let token = credentials.token
        let outcome = await Task.detached { await MacProbe.scan(candidates, token: token) }.value
        // A search that never really ran should not block the next one.
        if outcome.found == nil, outcome.probed < candidates.count { lastAttempt = .distantPast }
        var fields = [
            "found": String(outcome.found != nil),
            "probed": String(outcome.probed),
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            "otherDevices": String(outcome.answeredButNotOurs),
            "foundAtPosition": outcome.foundAtPosition.map(String.init) ?? "-",
            // NSURLError code -> count, e.g. "-1001:230,-1004:20".
            "errors": outcome.errors.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","),
        ]
        guard let found = outcome.found, CredentialStore.current?.token == credentials.token else {
            PassiveTrace.event("rediscovery.end", fields)
            return false
        }
        let name = credentials.dialOrder.first { PairingNumber.octets(of: $0) == nil }
        CredentialStore.save(WatchCredentials(host: found, fallbackHost: name, token: credentials.token))
        fields["result"] = "address-updated"
        PassiveTrace.event("rediscovery.end", fields)
        return true
    }
}

/// The network part of the search, off the main actor.
enum MacProbe {
    struct Outcome: Sendable {
        var found: String?
        var foundAtPosition: Int?
        var probed = 0
        var answeredButNotOurs = 0
        var errors: [Int: Int] = [:]
    }

    private enum Answer: Sendable {
        case ours
        case notOurs
        case failed(Int)
    }

    /// Measured on an Apple Watch: 40 probes at once with a 2 s limit took
    /// 65 s for 253 addresses and timed out even on the real Mac — watchOS
    /// lets only a few connections proceed at a time. Hence few and patient.
    static func scan(_ hosts: [String], token: String, concurrency: Int = 6, timeout: TimeInterval = 5) async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let keyID = PairingProof.keyID(for: token)

        var outcome = Outcome()
        var next = 0
        let positions = Dictionary(uniqueKeysWithValues: hosts.enumerated().map { ($1, $0 + 1) })
        await withTaskGroup(of: (String, Answer).self) { group in
            func add() {
                guard next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask { (host, await probe(host, session: session, token: token, keyID: keyID)) }
            }
            for _ in 0..<concurrency { add() }
            for await (host, answer) in group {
                outcome.probed += 1
                switch answer {
                case .ours:
                    outcome.found = host
                    outcome.foundAtPosition = positions[host]
                    group.cancelAll()
                    return
                case .notOurs:
                    outcome.answeredButNotOurs += 1
                case .failed(let code):
                    outcome.errors[code, default: 0] += 1
                }
                if Task.isCancelled { group.cancelAll(); return }
                add()
            }
        }
        return outcome
    }

    private static func probe(_ host: String, session: URLSession, token: String, keyID: String) async -> Answer {
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        guard let url = URL(string: "\(WatchCredentials.baseURL(for: host))/hello?k=\(keyID)&n=\(nonce)") else {
            return .failed(0)
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let hello = try? JSONDecoder().decode(HelloResponse.self, from: data),
                  hello.proof == PairingProof.proof(token: token, nonce: nonce) else { return .notOurs }
            return .ours
        } catch {
            return .failed((error as NSError).code)
        }
    }
}

#if DEBUG
/// Test hook: launch with -HRSimulateAddressChange to make the stored Mac
/// address wrong (same network, different last number, no alternate name),
/// exactly as if the router had moved the Mac.
enum DebugHooks {
    /// Simulator screenshots: -HRPreviewPaired shows the main screen without
    /// a real Mac (the simulator build has no Keychain access).
    static var previewPaired: Bool {
        #if targetEnvironment(simulator)
        return demo || ProcessInfo.processInfo.arguments.contains("-HRPreviewPaired")
        #else
        return false
        #endif
    }

    /// Simulator screenshots and video: -HRDemo shows a Live session with a
    /// changing reading, connected to a Mac, with no HealthKit or network.
    static var demo: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-HRDemo")
        #else
        return false
        #endif
    }

    static func applyLaunchArguments() {
        guard ProcessInfo.processInfo.arguments.contains("-HRSimulateAddressChange"),
              let credentials = CredentialStore.current,
              let known = credentials.dialOrder.first(where: { PairingNumber.octets(of: $0) != nil }),
              let octets = PairingNumber.octets(of: known) else { return }
        let wrong = octets[3] == 250 ? 251 : 250
        CredentialStore.save(WatchCredentials(host: "\(octets[0]).\(octets[1]).\(octets[2]).\(wrong)",
                                              fallbackHost: nil, token: credentials.token))
        PassiveTrace.log("debug.addressChangeSimulated")
    }
}
#endif
