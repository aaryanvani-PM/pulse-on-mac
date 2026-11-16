import Foundation

/// Bounded local record of every authorized packet and what the store did
/// with it. Times, provenance and decisions only — no BPM, no tokens.
/// File: ~/Library/Logs/HRMenuBar/ingest.jsonl
enum IngestLog {
    private static let lock = NSLock()
    private static let maxBytes = 400_000
    static let url: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = library.appendingPathComponent("Logs/HRMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ingest.jsonl")
    }()

    static func record(_ packet: WatchPacket, decision: String, receivedAt: Date) {
        var entry: [String: String] = [
            "received": String(format: "%.3f", receivedAt.timeIntervalSince1970),
            "event": packet.event,
            "mode": packet.mode?.rawValue ?? "live",
            "decision": decision,
        ]
        if let ts = packet.sampleTs { entry["sampleTs"] = String(format: "%.3f", ts) }
        if let queued = packet.queuedTs { entry["queuedTs"] = String(format: "%.3f", queued) }
        if let trigger = packet.trigger { entry["trigger"] = trigger.rawValue }
        if let state = packet.appState { entry["appState"] = state.rawValue }
        if let op = packet.op { entry["op"] = op }
        if let history = packet.history { entry["history"] = String(history.count) }
        write(entry)
    }

    static func note(_ stage: String) {
        write(["received": String(format: "%.3f", Date().timeIntervalSince1970), "event": stage])
    }

    private static func write(_ entry: [String: String]) {
        guard let url, var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? line.write(to: url)
            return
        }
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
           let old = try? Data(contentsOf: url) {
            let tail = old.suffix(maxBytes / 2)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[start...]).write(to: url, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
