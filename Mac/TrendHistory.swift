import Foundation
import Observation

struct TrendPoint: Codable, Equatable, Sendable {
    /// HealthKit's measurement time (seconds since 1970).
    let t: TimeInterval
    let bpm: Int
    var date: Date { Date(timeIntervalSince1970: t) }
}

/// Measurement history behind the trend chart: sorted by measurement time,
/// de-duplicated, kept for 30 days and saved to disk so a relaunch keeps it.
@MainActor
@Observable
final class TrendHistory {
    static let retention: TimeInterval = 31 * 86400
    /// Live sessions keep a point every 10 s; this leaves room for about
    /// two hours of Live a day on top of background readings.
    static let maxPoints = 80_000

    struct Bucket: Identifiable, Equatable {
        let start: Date
        let end: Date
        let min: Int
        let max: Int
        let average: Double
        /// Readings in the interval, so averages across buckets can be weighted.
        var count: Int = 1
        var id: Date { start }
    }

    private(set) var points: [TrendPoint] = []
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// ~/Library/Application Support/HRMenuBar/history.json (user-only).
    static var defaultURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = root.appendingPathComponent("HRMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([TrendPoint].self, from: data) {
            points = saved.sorted { $0.t < $1.t }
            prune()
        }
    }

    /// Returns how many points were actually new.
    @discardableResult
    func insert(_ new: [TrendPoint]) -> Int {
        guard !new.isEmpty else { return 0 }
        let before = points.count
        if new.count == 1, let last = points.last, new[0].t > last.t {
            points.append(new[0])           // common case: next reading in order
        } else {
            var seen = Set(points.map { Int(($0.t * 1000).rounded()) })
            var merged = points
            for point in new where seen.insert(Int((point.t * 1000).rounded())).inserted {
                merged.append(point)
            }
            guard merged.count != before else { return 0 }
            points = merged.sorted { $0.t < $1.t }
        }
        prune()
        scheduleSave()
        return max(0, points.count - before)
    }

    func clear() {
        points = []
        scheduleSave()
    }

    func buckets(from: Date, to: Date, width: TimeInterval) -> [Bucket] {
        let lower = from.timeIntervalSince1970, upper = to.timeIntervalSince1970
        var grouped: [Int: (min: Int, max: Int, sum: Int, count: Int)] = [:]
        for point in points where point.t >= lower && point.t <= upper {
            let index = Int((point.t - lower) / width)
            if let current = grouped[index] {
                grouped[index] = (Swift.min(current.min, point.bpm), Swift.max(current.max, point.bpm),
                                  current.sum + point.bpm, current.count + 1)
            } else {
                grouped[index] = (point.bpm, point.bpm, point.bpm, 1)
            }
        }
        return grouped.keys.sorted().map { index in
            let value = grouped[index]!
            let start = from.addingTimeInterval(Double(index) * width)
            return Bucket(start: start, end: start.addingTimeInterval(width), min: value.min, max: value.max,
                          average: Double(value.sum) / Double(value.count), count: value.count)
        }
    }

    /// One bucket per local calendar day, for the last `days` days up to
    /// and including today. Days without readings are left out.
    func dayBuckets(days: Int, endingAt now: Date, calendar: Calendar = .current) -> [Bucket] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let lower = first.timeIntervalSince1970
        var grouped: [Date: (min: Int, max: Int, sum: Int, count: Int)] = [:]
        for point in points where point.t >= lower && point.t <= now.timeIntervalSince1970 {
            let day = calendar.startOfDay(for: point.date)
            if let current = grouped[day] {
                grouped[day] = (Swift.min(current.min, point.bpm), Swift.max(current.max, point.bpm),
                                current.sum + point.bpm, current.count + 1)
            } else {
                grouped[day] = (point.bpm, point.bpm, point.bpm, 1)
            }
        }
        return grouped.keys.sorted().map { day in
            let value = grouped[day]!
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
            return Bucket(start: day, end: end, min: value.min, max: value.max,
                          average: Double(value.sum) / Double(value.count), count: value.count)
        }
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        if let first = points.first, first.t < cutoff { points.removeAll { $0.t < cutoff } }
        if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
    }

    private func scheduleSave() {
        guard let url, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.saveTask = nil
            guard let data = try? JSONEncoder().encode(self.points) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
