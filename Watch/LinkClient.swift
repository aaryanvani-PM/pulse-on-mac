import Foundation
import Observation

/// UI-facing link state for the watch app. Updated only by LinkClient.
@MainActor
@Observable
final class LinkStateStore {
    enum State: Equatable {
        case unpaired
        case idle
        case connected
        case unreachable(String)
    }

    private(set) var state: State = .unpaired

    func set(_ newState: State) { state = newState }
    func markPaired(host: String) { state = .idle }
    func markUnpaired() { state = .unpaired }
}

enum LinkError: LocalizedError {
    case wrongCode
    case badResponse

    var errorDescription: String? {
        switch self {
        case .wrongCode:
            return "Your Mac didn't accept that number. Enter the one it shows now."
        case .badResponse:
            return "Couldn't reach your Mac. Check it's on the same Wi‑Fi and Heart Rate is running."
        }
    }
}

/// Watch -> Mac sender over URLSession (TN3135: no raw sockets or Bonjour
/// browsing on watchOS). Plaintext HTTP is a documented development
/// limitation. Sends are retried with exponential backoff (2–8 s).
actor LinkClient {
    private let session: URLSession
    private weak var store: LinkStateStore?
    private var consecutiveFailures = 0
    private var nextAllowedSend = Date.distantPast
    /// The most recent failure reason (e.g. "timed out", "cannot find
    /// host"), for diagnostics surfaces like the passive status line.
    /// Quiet sends don't touch the badge but still record this.
    private(set) var lastFailureMessage: String?

    init(store: LinkStateStore) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        // watchOS Wi-Fi sleeps aggressively: the first request after idle can
        // take several seconds to wake the radio. Generous timeouts plus
        // waitsForConnectivity keep the pairing POST alive long enough.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
        if let credentials = CredentialStore.current {
            let host = credentials.host
            Task { await store.markPaired(host: host) }
        }
    }

    /// One-shot pairing against the code shown in the Mac menu bar.
    /// On success the issued token is stored in the Keychain.
    func pair(host: String, code: String) async throws {
        var request = URLRequest(url: URL(string: "http://\(host):5337/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(code: code))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LinkError.badResponse }
        guard http.statusCode == 200 else {
            throw http.statusCode == 403 ? LinkError.wrongCode : LinkError.badResponse
        }
        let pairResponse = try JSONDecoder().decode(PairResponse.self, from: data)
        // The address just answered, so it goes first; the Mac's .local
        // name is kept as an alternate for networks where it resolves.
        let hostname = pairResponse.host.flatMap { $0.isEmpty ? nil : $0 }
        CredentialStore.save(
            WatchCredentials(host: host, fallbackHost: hostname, token: pairResponse.token)
        )
        consecutiveFailures = 0
        nextAllowedSend = .distantPast
        await store?.markPaired(host: host)
    }

    /// Best-effort event send, reporting whether the packet was delivered.
    /// Safe to call every 2 s from the transmit loop; tries the preferred
    /// host, then the fallback, and swaps the stored order when the fallback
    /// wins (self-healing after DHCP or mDNS changes). Failures back off up
    /// to 8 s. `loud` failures surface "unreachable" on the watch badge —
    /// right for continuous mode (the user is watching); passive sends pass
    /// `loud: false` because a transient radio-sleep miss is normal and
    /// self-healing on the next wake, not worth an alarm.
    /// Pair with no typing: adopt the endpoint the Mac published to the
    /// user's private iCloud database. False when none is available.
    func pairFromCloud() async -> Bool {
        _ = await CloudRepair.attempt(reason: "first-pair", minimumInterval: 3)
        guard let credentials = CredentialStore.current else { return false }
        consecutiveFailures = 0
        nextAllowedSend = .distantPast
        await store?.markPaired(host: credentials.host)
        return true
    }

    @discardableResult
    func send(_ packet: WatchPacket, loud: Bool = true, allowRepair: Bool = true) async -> Bool {
        guard !Task.isCancelled, let credentials = CredentialStore.current else { return false }
        let now = Date()
        guard now >= nextAllowedSend else { return false }

        let hosts = credentials.dialOrder
        var lastError: Error = LinkError.badResponse

        for (index, host) in hosts.enumerated() {
            guard !Task.isCancelled, CredentialStore.current == credentials else { return false }
            do {
                var request = URLRequest(url: URL(string: "\(WatchCredentials.baseURL(for: host))/event")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(packet)
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw LinkError.badResponse
                }
                guard !Task.isCancelled, CredentialStore.current == credentials else { return false }
                if index != 0 {
                    // The fallback reached the Mac: make it the preferred host.
                    CredentialStore.save(
                        WatchCredentials(
                            host: host,
                            fallbackHost: hosts.first,
                            token: credentials.token
                        )
                    )
                }
                consecutiveFailures = 0
                nextAllowedSend = .distantPast
                lastFailureMessage = nil
                if packet.mode == .passive {
                    PassiveTrace.log("link.ok", op: packet.op, ["hostIndex": String(index), "hostKind": Self.kind(of: host)])
                }
                await store?.set(.connected)
                return true
            } catch {
                lastError = error
                // Passive sends only: a continuous session sends every 2 s.
                if packet.mode == .passive {
                    let nsError = error as NSError
                    PassiveTrace.log("link.fail", op: packet.op, [
                        "hostIndex": String(index), "hostKind": Self.kind(of: host),
                        "error": "\(nsError.domain) \(nsError.code)",
                    ])
                }
            }
        }

        // Every known address failed (or the key was refused): the Mac may
        // have moved. Ask iCloud for its current endpoint and retry once.
        if allowRepair, await CloudRepair.attempt(reason: "send-failed") {
            return await send(packet, loud: loud, allowRepair: false)
        }
        // Without iCloud: look for the Mac at the other addresses on the
        // network it was last seen on (only while the app is on screen).
        if allowRepair, !Task.isCancelled, (lastError as NSError).code != NSURLErrorCancelled {
            await store?.set(.unreachable("Looking for your Mac…"))
            if await Rediscovery.attempt(reason: "send-failed") {
                return await send(packet, loud: loud, allowRepair: false)
            }
            if !loud { await store?.set(.idle) }
        }

        consecutiveFailures += 1
        let backoff = TimeInterval(min(1 << min(consecutiveFailures, 4), 8))
        nextAllowedSend = Date().addingTimeInterval(backoff)
        lastFailureMessage = Self.message(for: lastError)
        if loud {
            await store?.set(.unreachable(lastFailureMessage ?? "Unreachable"))
        }
        return false
    }

    func unpair() async {
        CredentialStore.delete()
        await store?.markUnpaired()
    }

    /// Address kind for the trace — never the address itself.
    private static func kind(of host: String) -> String {
        host.lowercased().hasSuffix(".local") ? "mdns" : "address"
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach your Mac. Check both devices are on the same Wi-Fi and allow Local Network access for Heart Rate."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
