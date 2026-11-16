import Foundation
import WatchKit

/// Bounded, append-only local trace of the passive pipeline. One JSON object
/// per line: wall-clock time, process-run id, stage, optional operation id.
/// Holds stages, counts and timestamps only — never BPM, tokens, addresses
/// or payloads. Survives relaunch so chronology is preserved across wakes.
///
/// Retrieve without opening the Watch UI:
///   xcrun devicectl device copy from --device <ID> \
///     --domain-type appDataContainer --domain-identifier <your prefix>.HRWatchApp \
///     --source "Library/Application Support/passive-trace.jsonl" --destination <file>
enum PassiveTrace {
    /// Distinguishes process launches: a new id means watchOS relaunched us.
    static let runID = String(UUID().uuidString.prefix(6))
    private static let lock = NSLock()
    private static let maxBytes = 240_000
    private static let url: URL? = {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return root.appendingPathComponent("passive-trace.jsonl")
    }()

    static func newOp() -> String { String(UUID().uuidString.prefix(8)) }
    static func stamp(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }
    static func stamp(_ ts: TimeInterval) -> String { String(format: "%.3f", ts) }

    /// Main-actor entry point: also records the app state at this instant.
    @MainActor
    static func event(_ stage: String, op: String? = nil, _ fields: [String: String] = [:]) {
        var fields = fields
        switch WKApplication.shared().applicationState {
        case .active: fields["state"] = "active"
        case .inactive: fields["state"] = "inactive"
        default: fields["state"] = "background"
        }
        log(stage, op: op, fields)
    }

    static func log(_ stage: String, op: String? = nil, _ fields: [String: String] = [:]) {
        var entry = fields
        entry["t"] = stamp(Date())
        entry["run"] = runID
        entry["stage"] = stage
        if let op { entry["op"] = op }
        guard let url, var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? line.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
            return
        }
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
           let old = try? Data(contentsOf: url) {
            // Keep the newer half, cut at a line boundary.
            let tail = old.suffix(maxBytes / 2)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[start...]).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
