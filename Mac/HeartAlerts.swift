import Foundation
import UserNotifications

/// Optional notifications when readings stay above the high limit or below
/// the low limit for the chosen time. One alert per episode: it re-arms only
/// after a reading comes back 5 BPM inside the limit, and never repeats
/// within 30 minutes. Not a medical feature.
@MainActor
final class HeartAlerts {
    struct Episode {
        var active = false
        var lastAlert: Date?
    }

    enum Kind: Sendable { case high, low }

    static let rearmMargin = 5
    static let cooldown: TimeInterval = 30 * 60
    /// A reading older than this can't start an alert.
    static let freshness: TimeInterval = 20 * 60

    private let prefs: Preferences
    private var high = Episode()
    private var low = Episode()
    /// Injected so checks can run without posting real notifications.
    var post: (Kind, Int, Int) -> Void = { HeartAlerts.notify($0, limit: $1, minutes: $2) }

    init(prefs: Preferences) { self.prefs = prefs }

    /// Call after each new reading with the measurement history.
    func evaluate(points: [TrendPoint], now: Date = Date()) {
        guard let latest = points.last, now.timeIntervalSince(latest.date) <= Self.freshness else { return }
        let window = TimeInterval(prefs.sustainMinutes * 60)
        check(.high, enabled: prefs.highAlert, limit: prefs.highLimit, points: points, latest: latest,
              window: window, now: now, episode: &high)
        check(.low, enabled: prefs.lowAlert, limit: prefs.lowLimit, points: points, latest: latest,
              window: window, now: now, episode: &low)
    }

    private func check(_ kind: Kind, enabled: Bool, limit: Int, points: [TrendPoint], latest: TrendPoint,
                       window: TimeInterval, now: Date, episode: inout Episode) {
        let past: (Int) -> Bool = kind == .high ? { $0 > limit } : { $0 < limit }
        let backInside = kind == .high ? latest.bpm <= limit - Self.rearmMargin : latest.bpm >= limit + Self.rearmMargin
        if backInside { episode.active = false }
        guard enabled, !episode.active, past(latest.bpm) else { return }
        // How long readings have been past the limit without a break.
        var earliest = latest
        for point in points.reversed() {
            guard past(point.bpm) else { break }
            earliest = point
        }
        guard latest.t - earliest.t >= window else { return }
        if let last = episode.lastAlert, now.timeIntervalSince(last) < Self.cooldown { return }
        episode.active = true
        episode.lastAlert = now
        post(kind, limit, prefs.sustainMinutes)
    }

    nonisolated static func notify(_ kind: Kind, limit: Int, minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = kind == .high ? "Heart rate above \(limit) BPM" : "Heart rate below \(limit) BPM"
        content.body = "Your Apple Watch readings have stayed \(kind == .high ? "above" : "below") \(limit) BPM for at least \(minutes) minutes."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "heart-\(kind == .high ? "high" : "low")", content: content, trigger: nil))
    }

    /// Asks once, when the user first switches an alert on.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .authorized { return true }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func permissionDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}

/// Shows alerts as banners even while the popover is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
