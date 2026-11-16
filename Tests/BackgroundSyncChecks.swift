import Foundation

// Minimal server types keep the checks isolated from listeners and Keychain.
enum ServerState: Equatable { case listening, stopped, failed(String), waitingPermission(String) }
enum PairResult { case success(token: String), badCode, failure(String) }

@main struct BackgroundSyncChecks {
    @MainActor static func main() throws {
        // Existing diagnostic counters survive adding optional outcome fields.
        let oldDiagnostics = try JSONDecoder().decode(PassiveDiagnostics.self, from:
            Data("{\"backgroundObservers\":4,\"scheduledRefreshes\":0,\"backgroundDeliveries\":0}".utf8))
        precondition(oldDiagnostics.backgroundObservers == 4 && oldDiagnostics.lastBackgroundOutcome == nil)
        let now = Date()
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(WatchPacket.self, from: Data("{\"event\":\"hr\",\"bpm\":70,\"sampleTs\":100}".utf8))
        precondition(legacy.trigger == nil && legacy.appState == nil, "Old Watch packets must remain readable")
        let packet = WatchPacket(event: "hr", bpm: 71, sampleTs: now.timeIntervalSince1970,
                                 mode: .passive, trigger: .scheduledRefresh, appState: .background)
        let decoded = try decoder.decode(WatchPacket.self, from: JSONEncoder().encode(packet))
        precondition(decoded.trigger == .scheduledRefresh && decoded.appState == .background)
        let store = HeartRateStore()
        store.setServerState(.listening)
        store.ingest(decoded)
        precondition(store.currentBPM == 71 && store.lastBackgroundDeliveryAt != nil)
        precondition(store.status(at: now.addingTimeInterval(1201)) == .passiveQuiet)
        let count = store.samples.count
        store.ingest(decoded)
        precondition(store.samples.count == count, "Receipt retries must not add duplicate readings")
        store.ingest(WatchPacket(event: "hr", bpm: 65, sampleTs: now.addingTimeInterval(-1800).timeIntervalSince1970,
                                 mode: .passive, trigger: .observer, appState: .background))
        precondition(store.currentBPM == 71, "Delayed passive packets must not replace newer BPM")
        let foregroundStore = HeartRateStore()
        foregroundStore.ingest(WatchPacket(event: "hr", bpm: 72, sampleTs: now.timeIntervalSince1970,
                                          mode: .passive, trigger: .observer, appState: .active))
        precondition(foregroundStore.lastBackgroundDeliveryAt == nil, "Foreground observers are not background proof")
        let oldStore = HeartRateStore()
        oldStore.setServerState(.listening)
        oldStore.ingest(WatchPacket(event: "hr", bpm: 70, sampleTs: now.addingTimeInterval(-1800).timeIntervalSince1970,
                                   mode: .passive, trigger: .scheduledRefresh, appState: .background))
        precondition(oldStore.status(at: now) == .passiveQuiet, "Successful sync must preserve measurement age")
        oldStore.ingest(WatchPacket(event: "hr", bpm: 80, sampleTs: nil, mode: .passive))
        precondition(oldStore.currentBPM == 70, "Missing capture times must be rejected")
        let reading = ComplicationCache.Reading(bpm: 70, measuredAt: now)
        precondition(reading.isRecent(at: now.addingTimeInterval(1199)))
        precondition(!reading.isRecent(at: now.addingTimeInterval(1200)), "Widget must expire without waiting for OS reload")
        precondition(!reading.isRecent(at: now.addingTimeInterval(-61)), "Future readings must not look fresh")
        // Backfilled history fills the trend without moving the current value.
        let trendStore = HeartRateStore()
        var batch = WatchPacket(event: "hr", bpm: 66, sampleTs: now.timeIntervalSince1970, mode: .passive,
                                trigger: .scheduledRefresh, appState: .background)
        batch.history = [.init(t: now.timeIntervalSince1970 - 300, b: 61), .init(t: now.timeIntervalSince1970 - 600, b: 59),
                         .init(t: now.timeIntervalSince1970 - 300, b: 61), .init(t: now.timeIntervalSince1970 - 100, b: 999)]
        let wire = try decoder.decode(WatchPacket.self, from: JSONEncoder().encode(batch))
        trendStore.ingest(wire)
        trendStore.ingest(wire)
        precondition(trendStore.currentBPM == 66 && trendStore.samples.count == 1)
        precondition(trendStore.trend.points.map(\.bpm) == [59, 61, 66], "History must be sorted, deduplicated and validated")
        let buckets = trendStore.trend.buckets(from: now.addingTimeInterval(-900), to: now.addingTimeInterval(1), width: 1000)
        precondition(buckets.count == 1 && buckets[0].min == 59 && buckets[0].max == 66)
        // Pairing number: every private range round-trips, typos are caught.
        for (address, length) in [("192.168.1.8", 11), ("192.168.255.254", 11), ("10.0.0.2", 14),
                                  ("10.255.255.254", 14), ("172.16.0.5", 13), ("172.31.255.254", 13),
                                  ("169.254.10.20", 16), ("100.64.0.9", 16)] {
            let number = PairingNumber.encode(address: address, code: "0427")!
            precondition(number.count == length && PairingNumber.expectedLength(number) == length)
            let back = PairingNumber.decode(PairingNumber.grouped(number))!
            precondition(back.address == address && back.code == "0427", "Pairing number must round-trip")
            var typo = Array(number)
            typo[3] = typo[3] == "5" ? "6" : "5"
            precondition(PairingNumber.decode(String(typo)) == nil || String(typo) == number, "Single wrong digit must be rejected")
            precondition(PairingNumber.decode(String(number.dropLast())) == nil)
        }
        precondition(PairingNumber.encode(address: "Mac.local", code: "0427") == nil)
        precondition(PairingNumber.encode(address: "192.168.1.8", code: "123456") == nil)
        precondition(PairingNumber.decode("5123") == nil)
        print("PASS: pairing number encoding, decoding and typo rejection")
        print("PASS: backfilled history, deduplication and trend buckets")
        print("PASS: old/new wire compatibility and background provenance")
        print("PASS: duplicate/out-of-order delivery and honest measurement age")
        print("PASS: complication expiry and future timestamp handling")
    }
}
