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
    /// Which install and boot made the pending request. watchOS drops booked
    /// refreshes when the app is reinstalled or the Watch restarts, but this
    /// saved note survives both; without these, the app would wait for a
    /// refresh that never comes.
    private static let madeAtKey = "passiveSync.requestMadeAt"
    private static let installKey = "passiveSync.requestInstall"
    static var nextRequest: Date? { UserDefaults.standard.object(forKey: scheduledKey) as? Date }

    /// Changes whenever the app is reinstalled.
    private static var installID: String {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
        return String(Int(date.timeIntervalSince1970))
    }

    /// A pending request still counts only if this install made it since boot.
    private static var pendingRequestIsLive: Bool {
        let defaults = UserDefaults.standard
        guard let nextRequest, nextRequest > Date(),
              let madeAt = defaults.object(forKey: madeAtKey) as? Date,
              defaults.string(forKey: installKey) == installID else { return false }
        let bootedAt = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        return madeAt > bootedAt
    }

    static func scheduleIfNeeded() {
        guard isEnabled, CredentialStore.current != nil else { return }
        // Reopening the app must not keep pushing a pending task into the future.
        if pendingRequestIsLive { return }
        if let nextRequest, nextRequest > Date() {
            PassiveTrace.event("refresh.staleBooking", ["was": PassiveTrace.stamp(nextRequest)])
        }
        let preferred = Date().addingTimeInterval(interval)
        UserDefaults.standard.set(preferred, forKey: scheduledKey)
        UserDefaults.standard.set(Date(), forKey: madeAtKey)
        UserDefaults.standard.set(installID, forKey: installKey)
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
    static func clearSchedule() {
        UserDefaults.standard.removeObject(forKey: scheduledKey)
        UserDefaults.standard.removeObject(forKey: madeAtKey)
    }
}

