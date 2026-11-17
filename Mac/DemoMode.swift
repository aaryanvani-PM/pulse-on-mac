import Foundation

/// Screenshot and video mode: launch with `-HRDemo`.
///
///   open Build/HRMenuBar.app --args -HRDemo
///
/// Fills the trend chart with a believable day of readings (sleep, a
/// morning run, a lunchtime walk, an afternoon meeting) and then ticks a
/// live reading every couple of seconds. Nothing is saved to disk, the
/// receiver doesn't start, and the Connection section shows a made-up
/// address so a screenshot never reveals the real network.
enum DemoMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-HRDemo")
    static let address = "192.168.1.20"
    static let code = "4827"

    @MainActor
    static func start(_ store: HeartRateStore) {
        store.configure(pairingCode: code, localAddress: address)
        store.setServerState(.listening)
        let now = Date().timeIntervalSince1970
        var generator = SeededRandom(seed: 7)

        // A day of background readings, one every 5 minutes.
        var points: [TrendPoint] = []
        var t = now - 24 * 3600
        while t < now - 3600 {
            let bpm = typical(at: Date(timeIntervalSince1970: t)) + generator.next(in: -3...3)
            points.append(TrendPoint(t: t, bpm: bpm))
            t += 300
        }
        // The last hour as a Live session: a reading every 10 seconds,
        // drifting gently around a working heart rate.
        var bpm = 74
        while t < now - 5 {
            bpm = min(96, max(68, bpm + generator.next(in: -2...2)))
            points.append(TrendPoint(t: t, bpm: bpm))
            t += 10
        }
        store.trend.insert(points)

        // -HRDemoBPM <n> holds the live reading at n, to match another shot.
        let args = ProcessInfo.processInfo.arguments
        let fixed = args.firstIndex(of: "-HRDemoBPM").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        Task { @MainActor in
            var live = bpm
            var random = SeededRandom(seed: 11)
            while true {
                live = fixed ?? min(98, max(70, live + random.next(in: -2...2)))
                store.ingest(WatchPacket(event: PacketEvent.heartRate, bpm: live,
                                         sampleTs: Date().timeIntervalSince1970, mode: .live))
                try? await Task.sleep(for: .milliseconds(Int.random(in: 1500...3500)))
            }
        }
    }

    /// Heart rate for a typical weekday at this local time of day.
    private static func typical(at date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        switch hour {
        case ..<6.5: return 56 + Int(3 * sin(hour * 2))           // asleep
        case ..<7.25: return 66                                     // waking up
        case ..<7.6: return 118 + Int((hour - 7.25) * 90)          // run, building
        case ..<8.0: return 150 - Int((hour - 7.6) * 150)          // run, easing off
        case ..<12.5: return 74
        case ..<13.0: return 96                                     // lunchtime walk
        case ..<15.0: return 72
        case ..<15.75: return 86                                    // meeting
        case ..<19.0: return 75
        case ..<23.0: return 70
        default: return 62
        }
    }
}

/// Small deterministic generator so the demo day looks the same each run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 33) % span)
    }
}
