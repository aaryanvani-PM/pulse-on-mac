import Foundation

/// Contains only counts and times, never BPM, addresses or credentials.
struct PassiveDiagnostics: Codable {
    var backgroundObservers = 0
    var scheduledRefreshes = 0
    var backgroundDeliveries = 0
    var lastBackgroundWake: Date?
    var lastBackgroundDelivery: Date?
    var lastBackgroundOutcome: String?
    var lastBackgroundOutcomeAt: Date?
    private static let key = "passiveSync.diagnostics.v1"

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    private func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    mutating func recordOutcome(_ text: String) {
        lastBackgroundOutcome = text
        lastBackgroundOutcomeAt = Date()
        save()
    }
    mutating func recordWake(trigger: WatchPacket.SyncTrigger, state: WatchPacket.AppState) {
        if trigger == .scheduledRefresh { scheduledRefreshes += 1 }
        if state == .background {
            lastBackgroundWake = Date()
            if trigger == .observer { backgroundObservers += 1 }
        }
        save()
    }
    mutating func recordDelivery(trigger: WatchPacket.SyncTrigger, state: WatchPacket.AppState) {
        if state == .background, trigger != .foreground {
            backgroundDeliveries += 1
            lastBackgroundDelivery = Date()
        }
        save()
    }
}
