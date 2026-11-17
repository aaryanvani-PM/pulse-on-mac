import Foundation
import Network

enum ServerState: Sendable, Equatable {
    case listening
    /// Listener exists but is blocked — typically the macOS Local Network
    /// permission prompt has not been accepted yet.
    case waitingPermission(String)
    case failed(String)
    case stopped
}

enum PairResult: Sendable, Equatable {
    case success
    case badCode
    case failure(String)
}

/// Minimal HTTP/1.1 server over NWListener. Low-level networking is
/// unrestricted on macOS (unlike watchOS — the watch side uses URLSession).
///
///   POST /pair   PairRequest (key + code proof) -> 200 PairResponse | 403
///   POST /event  SealedPacket (encrypted)       -> 204 | 401 | 409
///
/// All connection state is confined to `queue`; UI updates hop to MainActor.
/// Idle connections are swept after 120 s. Keep-alive is supported so
/// URLSession reuses one connection instead of churning per POST.
final class WatchHTTPServer: @unchecked Sendable {

    private struct ConnState {
        let nw: NWConnection
        var buffer: [UInt8] = []
        var method = ""
        var path = ""
        var contentLength = 0
        var headersParsed = false
        var lastActivity = Date()
    }

    private let queue = DispatchQueue(label: "com.aryanvani.hrlink.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnState] = [:]
    private var bindRetries = 0
    private let credentials: MacCredentials
    /// Confined to `queue`, like connection state.
    private var replayGuard = ReplayGuard()
    private let onEvent: @MainActor (WatchPacket) -> Void
    private let onPair: @MainActor (PairResult) -> Void
    private let onState: @MainActor (ServerState) -> Void
    /// A paired-looking Watch sent something this Mac couldn't open.
    var onRejected: (@MainActor () -> Void)?

    init(
        credentials: MacCredentials,
        onEvent: @escaping @MainActor (WatchPacket) -> Void,
        onPair: @escaping @MainActor (PairResult) -> Void,
        onState: @escaping @MainActor (ServerState) -> Void
    ) {
        self.credentials = credentials
        self.onEvent = onEvent
        self.onPair = onPair
        self.onState = onState
    }

    func start(port: UInt16 = 5337) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            do {
                let parameters = NWParameters.tcp
                // SO_REUSEADDR: lets the listener rebind immediately after a
                // restart even when the previous instance's keep-alive
                // connections are still in TIME_WAIT. Without this, killing
                // the app while the watch is streaming leaves the port
                // unbindable for ~1-2 minutes.
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: endpointPort)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.bindRetries = 0
                        Task { @MainActor in self.onState(.listening) }
                    case .waiting(let error):
                        Task { @MainActor in self.onState(.waitingPermission(error.localizedDescription)) }
                    case .failed(let error):
                        let message = error.localizedDescription
                        let shouldRetry = self.listener != nil && self.bindRetries < 5
                        if shouldRetry {
                            self.bindRetries += 1
                            self.listener = nil
                            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                                self?.start()
                            }
                        }
                        Task { @MainActor in self.onState(.failed(message)) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
                scheduleSweep()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self.onState(.failed(message)) }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for state in self.connections.values { state.nw.cancel() }
            self.connections.removeAll()
            Task { @MainActor in self.onState(.stopped) }
        }
    }

    // MARK: - Connection handling (all on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = ConnState(nw: connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id: id) }
        }
        connection.start(queue: queue)
        receiveLoop(connection, id: id)
    }

    private func close(id: ObjectIdentifier) {
        queue.async { [weak self] in
            guard let self, let state = self.connections.removeValue(forKey: id) else { return }
            state.nw.cancel()
        }
    }

    private func receiveLoop(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.ingest(id: id, data: data)
            }
            if error != nil || isComplete {
                self.close(id: id)
            } else {
                self.receiveLoop(connection, id: id)
            }
        }
    }

    private func ingest(id: ObjectIdentifier, data: Data) {
        guard var state = connections[id] else { return }
        state.lastActivity = Date()
        state.buffer.append(contentsOf: data)
        // Overall buffer cap: even after headers, a client streaming
        // garbage (pipelined requests, endless body) must not grow
        // memory unbounded.
        if state.buffer.count > 32768 {
            connections.removeValue(forKey: id)?.nw.cancel()
            return
        }

        if !state.headersParsed {
            guard let headerEnd = Self.firstIndexOf(state.buffer, [13, 10, 13, 10]) else {
                if state.buffer.count > 16384 {
                    connections.removeValue(forKey: id)?.nw.cancel()
                } else {
                    connections[id] = state
                }
                return
            }
            let headerText = String(decoding: state.buffer[0..<headerEnd], as: UTF8.self)
            let lines = headerText.components(separatedBy: "\r\n")
            let requestParts = (lines.first ?? "").split(separator: " ").map(String.init)
            state.method = requestParts.first ?? ""
            state.path = requestParts.count > 1 ? requestParts[1] : ""
            for line in lines.dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    // Bounds: a negative length would pass the
                    // `count >= length` check below and crash the
                    // removeSubrange; oversized bodies are rejected
                    // outright rather than buffered.
                    guard let length = Int(
                        lower.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)
                    ), length >= 0, length <= 16384 else {
                        connections.removeValue(forKey: id)?.nw.cancel()
                        return
                    }
                    state.contentLength = length
                }
            }
            state.buffer.removeSubrange(0..<(headerEnd + 4))
            state.headersParsed = true
        }

        if state.buffer.count >= state.contentLength {
            let body = state.contentLength > 0 ? Data(state.buffer.prefix(state.contentLength)) : Data()
            state.buffer.removeSubrange(0..<state.contentLength)
            let method = state.method
            let path = state.path
            state.headersParsed = false
            state.method = ""
            state.path = ""
            connections[id] = state
            handleRequest(id: id, method: method, path: path, body: body)
            if !state.buffer.isEmpty {
                // A pipelined request is already buffered; parse it too.
                ingest(id: id, data: Data())
            }
        } else {
            connections[id] = state
        }
    }

    private func handleRequest(id: ObjectIdentifier, method: String, path: String, body: Data) {
        if method == "GET", path == "/ping" {
            // Local self-check by the connection monitor. Not logged.
            respond(id: id, status: 204)
            return
        }
        if method == "GET", path.hasPrefix("/hello?") {
            // Identity check used by a paired Watch to find this Mac again
            // after its address changes. Reveals nothing without the key.
            let items = URLComponents(string: path)?.queryItems ?? []
            let keyID = items.first { $0.name == "k" }?.value ?? ""
            let nonce = items.first { $0.name == "n" }?.value ?? ""
            if let proof = credentials.proof(keyID: keyID, nonce: nonce),
               let payload = try? JSONEncoder().encode(HelloResponse(proof: proof)) {
                respond(id: id, status: 200, body: payload)
                IngestLog.note("hello-answered")
            } else {
                respond(id: id, status: 404)
                IngestLog.note("hello-unknown-key")
            }
            return
        }
        guard method == "POST" else {
            respond(id: id, status: 405)
            return
        }

        switch path {
        case "/pair":
            guard let request = try? JSONDecoder().decode(PairRequest.self, from: body) else {
                // Includes Watch builds from before encryption.
                respond(id: id, status: 400)
                return
            }
            if let paired = credentials.pair(request) {
                respond(id: id, status: 200, body: try? JSONEncoder().encode(paired.response))
                Task { @MainActor in onPair(.success) }
            } else {
                respond(id: id, status: 403)
                Task { @MainActor in onPair(.badCode) }
            }

        case "/event":
            guard let sealed = try? JSONDecoder().decode(SealedPacket.self, from: body) else {
                respond(id: id, status: 400)
                return
            }
            // Unknown key, wrong key or tampered: indistinguishable on purpose.
            guard let secret = credentials.secret(forKeyID: sealed.k),
                  let opened = try? SecureChannel.open(sealed, secret: secret) else {
                respond(id: id, status: 401)
                if let onRejected { Task { @MainActor in onRejected() } }
                return
            }
            guard replayGuard.accept(nonce: opened.nonce, sent: opened.sent) else {
                respond(id: id, status: 409)
                IngestLog.note("replay-or-stale-rejected")
                return
            }
            let packet = opened.packet
            respond(id: id, status: 204)
            Task { @MainActor in onEvent(packet) }

        default:
            respond(id: id, status: 404)
        }
    }

    private func respond(id: ObjectIdentifier, status: Int, body: Data? = nil) {
        guard let state = connections[id] else { return }
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        default: reason = "Error"
        }
        var out = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: keep-alive\r\n\r\n".utf8
        )
        if let body { out.append(body) }
        state.nw.send(content: out, completion: .contentProcessed { _ in })
    }

    private func scheduleSweep() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            let now = Date()
            for (id, state) in self.connections where now.timeIntervalSince(state.lastActivity) > 120 {
                self.connections.removeValue(forKey: id)?.nw.cancel()
            }
            if self.listener != nil { scheduleSweep() }
        }
    }

    private static func firstIndexOf(_ array: [UInt8], _ pattern: [UInt8]) -> Int? {
        guard pattern.count <= array.count else { return nil }
        search: for index in 0...(array.count - pattern.count) {
            for offset in 0..<pattern.count where array[index + offset] != pattern[offset] {
                continue search
            }
            return index
        }
        return nil
    }
}
