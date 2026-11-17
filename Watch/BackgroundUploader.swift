import Foundation

/// System-owned file upload, independent of the app's short wake runtime.
/// Delegate events are delivered on OperationQueue.main; all state is MainActor.
@MainActor
final class BackgroundUploader: NSObject, URLSessionTaskDelegate {
    static let identifier = "com.aryanvani.hrlink.passive-upload.v1"
    static let shared = BackgroundUploader()
    /// watchOS decides when a background transfer actually starts; a task
    /// queued from the background can sit for minutes. A short resource
    /// timeout would fail it before the system ever tried.
    static let resourceTimeout: TimeInterval = 300
    /// A pending upload older than this is replaced by a newer reading.
    static let supersedeAfter: TimeInterval = 90
    private var eventWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var eventsFinishedAt: Date?
    private var lastSuccessAt: Date?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func restore() { _ = session }

    /// Trace what the system still holds for us at process launch.
    func traceOutstanding() {
        Task { @MainActor in
            let tasks = await session.allTasks
            PassiveTrace.event("uploader.restore", ["outstanding": String(tasks.count)])
        }
    }

    func waitForEvents() async {
        restore()
        // Only a finish-events callback from THIS wake counts. A stale flag
        // from an earlier wake would end the task before delegates ran.
        if let finished = eventsFinishedAt, Date().timeIntervalSince(finished) < 5 {
            eventsFinishedAt = nil
            return
        }
        eventsFinishedAt = nil
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        eventWaiters[id] = continuation
        // AsyncStream exits on task cancellation, so an expired OS runtime
        // cannot leave the refresh handler stuck on a continuation.
        for await _ in stream { break }
        eventWaiters.removeValue(forKey: id)
    }

    /// True once if an upload was confirmed by the Mac during this wake.
    /// Lets the caller use the remaining runtime to queue a newer sample.
    func consumeRecentSuccess() -> Bool {
        defer { lastSuccessAt = nil }
        guard let lastSuccessAt else { return false }
        return Date().timeIntervalSince(lastSuccessAt) < 30
    }

    func enqueue(_ packet: WatchPacket) async throws {
        let op = packet.op ?? PassiveTrace.newOp()
        guard BackgroundRefresh.isEnabled, let credentials = CredentialStore.current else {
            PassiveTrace.event("upload.notQueued", op: op, ["why": "disabled-or-unpaired"])
            record("Not queued: background sync off or pairing unavailable")
            return
        }
        let tasks = await session.allTasks
        guard !Task.isCancelled, BackgroundRefresh.isEnabled,
              CredentialStore.current == credentials else { return }
        // Keep the system queue bounded. A fresh upload gets time to wake
        // the radio; when it finishes, the completion wake queues whatever
        // sample is newest by then (see PassiveMonitor.followUp).
        if let pending = tasks.first(where: { $0.state != .completed && $0.state != .canceling }) {
            let info = Self.parse(pending.taskDescription)
            let age = info?.queuedAt.map { Date().timeIntervalSince1970 - $0 } ?? 0
            var fields = ["pendingTask": String(pending.taskIdentifier), "pendingAge": String(format: "%.0f", age)]
            if let pendingOp = info?.op { fields["pendingOp"] = pendingOp }
            // A stuck upload must not hold newer readings back. Seen on
            // device: a transfer that never connected blocked them for 10
            // minutes. This packet carries every reading since the last one
            // the Mac confirmed, so it fully replaces the stuck one.
            guard age > Self.supersedeAfter else {
                PassiveTrace.event("upload.skipPending", op: op, fields)
                record("Upload already pending with watchOS")
                return
            }
            pending.cancel()
            PassiveTrace.event("upload.superseded", op: op, fields)
        }
        let folder = try uploadFolder()
        // No other upload is active (a stuck one was just cancelled), so
        // leftover files may be removed without affecting a live transfer.
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        var packet = packet
        packet.op = op
        packet.queuedTs = Date().timeIntervalSince1970
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        // Sealed before it is queued: the file and the request carry only ciphertext.
        try JSONEncoder().encode(SecureChannel.seal(packet, secret: credentials.token))
            .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        start(file: file, credentials: credentials, hostIndex: 0, op: op, queuedAt: packet.queuedTs ?? 0)
        record("Queued with watchOS · waiting for Mac confirmation")
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    private func uploadFolder() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = root.appendingPathComponent("PassiveUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func start(file: URL, credentials: WatchCredentials, hostIndex: Int, op: String, queuedAt: TimeInterval) {
        let hosts = credentials.dialOrder
        guard hosts.indices.contains(hostIndex),
              let url = URL(string: "\(WatchCredentials.baseURL(for: hosts[hostIndex]))/event") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Non-secret key id, so completion can tell which pairing queued it.
        request.setValue(PairingProof.keyID(for: credentials.token), forHTTPHeaderField: "X-Pulse-Key")
        let task = session.uploadTask(with: request, fromFile: file)
        // Non-secret file identity, host position, operation id and queue
        // time survive process relaunch.
        task.taskDescription = "\(hostIndex)|\(file.lastPathComponent)|\(op)|\(PassiveTrace.stamp(queuedAt))"
        task.resume()
        PassiveTrace.event("upload.queued", op: op, [
            "task": String(task.taskIdentifier),
            "hostIndex": String(hostIndex),
            // Kind only, never the address itself.
            "hostKind": hosts[hostIndex].lowercased().hasSuffix(".local") ? "mdns" : "address",
        ])
    }

    private struct TaskInfo {
        let hostIndex: Int
        let fileName: String
        let op: String?
        let queuedAt: TimeInterval?
    }

    /// "index|file" (build 3) or "index|file|op|queuedAt".
    nonisolated private static func parse(_ description: String?) -> TaskInfo? {
        guard let description else { return nil }
        let parts = description.split(separator: "|").map(String.init)
        guard parts.count >= 2, let index = Int(parts[0]) else { return nil }
        return TaskInfo(hostIndex: index, fileName: parts[1],
                        op: parts.count > 2 ? parts[2] : nil,
                        queuedAt: parts.count > 3 ? TimeInterval(parts[3]) : nil)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // When the system actually put the request on the wire, as opposed
        // to when we queued it.
        var fields = ["task": String(task.taskIdentifier),
                      "transactions": String(metrics.transactionMetrics.count)]
        if let last = metrics.transactionMetrics.last {
            if let start = last.fetchStartDate { fields["fetchStart"] = PassiveTrace.stamp(start) }
            if let sent = last.requestEndDate { fields["requestEnd"] = PassiveTrace.stamp(sent) }
            if let end = last.responseEndDate { fields["responseEnd"] = PassiveTrace.stamp(end) }
        }
        PassiveTrace.log("upload.metrics", op: Self.parse(task.taskDescription)?.op, fields)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { complete(task, error: error) }
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        guard let info = Self.parse(task.taskDescription), let folder = try? uploadFolder() else { return }
        let index = info.hostIndex
        let name = info.fileName
        guard name == URL(fileURLWithPath: name).lastPathComponent else { return }
        let file = folder.appendingPathComponent(name)
        let status = (task.response as? HTTPURLResponse)?.statusCode
        var fields = ["task": String(task.taskIdentifier), "hostIndex": String(index)]
        if let status { fields["http"] = String(status) }
        if let error = error as NSError? { fields["error"] = "\(error.domain) \(error.code)" }
        if let queuedAt = info.queuedAt {
            fields["sinceQueued"] = String(format: "%.1f", Date().timeIntervalSince1970 - queuedAt)
        }
        PassiveTrace.event("upload.complete", op: info.op, fields)
        if (error as NSError?)?.code == NSURLErrorCancelled {
            // Replaced by a newer upload (or unpaired): nothing to retry.
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard BackgroundRefresh.isEnabled, let credentials = CredentialStore.current,
              task.originalRequest?.value(forHTTPHeaderField: "X-Pulse-Key") == PairingProof.keyID(for: credentials.token) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if error == nil, let status, (200..<300).contains(status),
           let data = try? Data(contentsOf: file), let sealed = try? JSONDecoder().decode(SealedPacket.self, from: data),
           let packet = try? SecureChannel.open(sealed, secret: credentials.token).packet {
            if let ts = packet.sampleTs {
                let previous = UserDefaults.standard.double(forKey: "passiveSync.deliveredTs.v2")
                UserDefaults.standard.set(max(previous, ts), forKey: "passiveSync.deliveredTs.v2")
                PassiveTrace.event("upload.confirmed", op: info.op, ["sampleTs": PassiveTrace.stamp(ts)])
            }
            let hosts = credentials.dialOrder
            if index != 0, hosts.indices.contains(index) {
                // The alternate address reached the Mac: prefer it from now
                // on, so later uploads don't first wait out a dead address.
                CredentialStore.save(WatchCredentials(host: hosts[index], fallbackHost: hosts.first,
                                                      token: credentials.token))
                PassiveTrace.event("upload.hostSwapped", op: info.op)
            }
            var diagnostics = PassiveDiagnostics.load()
            diagnostics.recordDelivery(trigger: packet.trigger ?? .observer, state: packet.appState ?? .background)
            diagnostics.recordOutcome("Mac confirmed background upload")
            lastSuccessAt = Date()
            try? FileManager.default.removeItem(at: file)
            return
        }
        // Never retry revoked credentials. A transport failure may try the
        // alternate paired host once; later wakes retry the latest reading.
        if error != nil, index == 0, credentials.dialOrder.count > 1 {
            // Keeps the original queue time, so its age counts the whole wait.
            start(file: file, credentials: credentials, hostIndex: 1,
                  op: info.op ?? PassiveTrace.newOp(), queuedAt: info.queuedAt ?? Date().timeIntervalSince1970)
            record("Retrying alternate Mac address")
            return
        }
        record("Upload failed: \(error?.localizedDescription ?? "HTTP \(status ?? 0)")")
        try? FileManager.default.removeItem(at: file)
        // The Mac may have a new address or key; refresh from iCloud so the
        // next wake can reach it. Best effort within this wake's runtime.
        Task { await CloudRepair.attempt(reason: "upload-failed") }
    }

    private func record(_ message: String) {
        var diagnostics = PassiveDiagnostics.load()
        diagnostics.recordOutcome(message)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            PassiveTrace.event("uploader.eventsFinished", ["waiters": String(eventWaiters.count)])
            if eventWaiters.isEmpty { eventsFinishedAt = Date() }
            let waiters = Array(eventWaiters.values)
            eventWaiters.removeAll()
            waiters.forEach { $0.yield(()); $0.finish() }
        }
    }
}
