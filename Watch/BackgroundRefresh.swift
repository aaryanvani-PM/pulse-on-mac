import Foundation
import WatchKit

@MainActor
enum BackgroundRefresh {
    static let identifier = "HeartRatePassiveRefresh"
    // Apple's stated budget for an app with a complication on the active
    // face is roughly four refreshes an hour; asking for less wastes it.
    static let interval: TimeInterval = 15 * 60
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "passiveSyncEnabled") as? Bool ?? true
    }
    private static let scheduledKey = "passiveSync.nextRefresh"
    static var nextRequest: Date? { UserDefaults.standard.object(forKey: scheduledKey) as? Date }

    static func scheduleIfNeeded() {
        guard isEnabled, CredentialStore.current != nil else { return }
        // Reopening the app must not keep pushing a pending task into the future.
        if let nextRequest, nextRequest > Date() { return }
        let preferred = Date().addingTimeInterval(interval)
        UserDefaults.standard.set(preferred, forKey: scheduledKey)
        PassiveTrace.event("refresh.request", ["preferred": PassiveTrace.stamp(preferred)])
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferred, userInfo: identifier as NSString
        ) { error in
            if let error {
                PassiveTrace.log("refresh.requestFailed", ["error": error.localizedDescription])
                UserDefaults.standard.removeObject(forKey: scheduledKey)
                UserDefaults.standard.set(error.localizedDescription, forKey: "passiveSync.scheduleError")
            } else {
                UserDefaults.standard.removeObject(forKey: "passiveSync.scheduleError")
            }
        }
    }

    // watchOS has no cancellation API here. A previously scheduled task may
    // arrive after opt-out; the handler checks the current preference and pairing.
    static func clearSchedule() { UserDefaults.standard.removeObject(forKey: scheduledKey) }
}

