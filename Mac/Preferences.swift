import Foundation
import Observation

/// User settings for the menu bar and alerts, saved in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case heartAndNumber, numberOnly, heartOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .heartAndNumber: return "Heart and number"
            case .numberOnly: return "Number only"
            case .heartOnly: return "Heart only"
            }
        }
    }

    enum Zone { case normal, high, low }

    @ObservationIgnored private let defaults: UserDefaults

    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// Tint the menu-bar number when the reading is past the high or low limit.
    var colorOutsideLimits: Bool { didSet { defaults.set(colorOutsideLimits, forKey: "colorOutsideLimits") } }
    /// Show only the heart when the shown reading isn't recent.
    var heartOnlyWhenNotRecent: Bool { didSet { defaults.set(heartOnlyWhenNotRecent, forKey: "heartOnlyWhenNotRecent") } }

    var highAlert: Bool { didSet { defaults.set(highAlert, forKey: "highAlert") } }
    var highLimit: Int { didSet { defaults.set(highLimit, forKey: "highLimit") } }
    var lowAlert: Bool { didSet { defaults.set(lowAlert, forKey: "lowAlert") } }
    var lowLimit: Int { didSet { defaults.set(lowLimit, forKey: "lowLimit") } }
    /// How long readings must stay past a limit before an alert.
    var sustainMinutes: Int { didSet { defaults.set(sustainMinutes, forKey: "sustainMinutes") } }

    static let highChoices = Array(stride(from: 100, through: 180, by: 5))
    static let lowChoices = Array(stride(from: 35, through: 60, by: 5))
    static let sustainChoices = [2, 5, 10, 15]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .heartAndNumber
        colorOutsideLimits = defaults.object(forKey: "colorOutsideLimits") as? Bool ?? true
        heartOnlyWhenNotRecent = defaults.bool(forKey: "heartOnlyWhenNotRecent")
        highAlert = defaults.bool(forKey: "highAlert")
        lowAlert = defaults.bool(forKey: "lowAlert")
        let high = defaults.integer(forKey: "highLimit")
        highLimit = Self.highChoices.contains(high) ? high : 120
        let low = defaults.integer(forKey: "lowLimit")
        lowLimit = Self.lowChoices.contains(low) ? low : 45
        let sustain = defaults.integer(forKey: "sustainMinutes")
        sustainMinutes = Self.sustainChoices.contains(sustain) ? sustain : 5
    }

    func zone(for bpm: Int) -> Zone {
        if bpm > highLimit { return .high }
        if bpm < lowLimit { return .low }
        return .normal
    }
}
