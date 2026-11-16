import Foundation

/// One local reading shared with the widget; no pairing keys or health history.
enum ComplicationCache {
    /// App Group ids are unique per developer team, so the id comes from the
    /// build (Info.plist key HRAppGroup) rather than being fixed in code.
    static let group = Bundle.main.object(forInfoDictionaryKey: "HRAppGroup") as? String ?? ""
    static let kind = "HeartRateComplication"
    struct Reading: Codable, Sendable {
        let bpm: Int
        let measuredAt: Date
        func isRecent(at now: Date) -> Bool {
            let age = now.timeIntervalSince(measuredAt)
            return age >= -60 && age < 20 * 60
        }
    }
    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("latest-reading.json")
    }
    static func load() -> Reading? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Reading.self, from: data) else { return nil }
        return value
    }
    @discardableResult
    static func save(bpm: Int, measuredAt: Date) -> Bool {
        if let previous = load(), previous.measuredAt >= measuredAt { return false }
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(Reading(bpm: bpm, measuredAt: measuredAt)) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}
