import Foundation

// Minimal server types keep the checks isolated from listeners and Keychain.
enum ServerState: Equatable { case listening, stopped, failed(String), waitingPermission(String) }
enum PairResult { case success, badCode, failure(String) }

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
        // Encryption: both sides derive the same secret; a wrong code can't.
        let watchPrivate = SecureChannel.newKeyPair(), macPrivate = SecureChannel.newKeyPair()
        let watchKey = watchPrivate.publicKey.rawRepresentation, macKey = macPrivate.publicKey.rawRepresentation
        precondition(SecureChannel.codeProof(code: "0427", watchKey: watchKey) != SecureChannel.codeProof(code: "0428", watchKey: watchKey))
        let watchSecret = try SecureChannel.sharedSecret(privateKey: watchPrivate, peerKey: macKey, watchKey: watchKey, macKey: macKey, code: "0427")
        let macSecret = try SecureChannel.sharedSecret(privateKey: macPrivate, peerKey: watchKey, watchKey: watchKey, macKey: macKey, code: "0427")
        precondition(watchSecret == macSecret && watchSecret.count == 64, "Pairing must agree one 32-byte secret")
        let otherCode = try SecureChannel.sharedSecret(privateKey: macPrivate, peerKey: watchKey, watchKey: watchKey, macKey: macKey, code: "9999")
        precondition(otherCode != watchSecret)
        precondition(SecureChannel.confirmation(secret: macSecret, macKey: macKey) == SecureChannel.confirmation(secret: watchSecret, macKey: macKey))
        // Readings: round-trip, ciphertext hides the value, tampering and wrong keys fail.
        let liveReading = WatchPacket(event: "hr", bpm: 88, sampleTs: now.timeIntervalSince1970, mode: .live)
        let sealed = try SecureChannel.seal(liveReading, secret: watchSecret)
        let wireText = String(data: try JSONEncoder().encode(sealed), encoding: .utf8) ?? ""
        precondition(!wireText.contains("bpm") && !wireText.contains("sampleTs"), "No plaintext fields on the wire")
        let opened = try SecureChannel.open(sealed, secret: macSecret)
        precondition(opened.packet.bpm == 88 && abs(opened.sent.timeIntervalSince(now)) < 5)
        var tamperedBytes = Data(base64Encoded: sealed.box)!
        tamperedBytes[tamperedBytes.count / 2] ^= 0x01
        let tampered = SealedPacket(v: sealed.v, k: sealed.k, box: tamperedBytes.base64EncodedString())
        precondition((try? SecureChannel.open(tampered, secret: macSecret)) == nil, "Tampered packets must fail")
        precondition((try? SecureChannel.open(sealed, secret: otherCode)) == nil, "Wrong key must fail")
        let relabelled = SealedPacket(v: sealed.v, k: "0000000000000000", box: sealed.box)
        precondition((try? SecureChannel.open(relabelled, secret: macSecret)) == nil, "Key id is authenticated")
        // Replays and stale packets are refused.
        var replayGuard = ReplayGuard()
        precondition(replayGuard.accept(nonce: opened.nonce, sent: opened.sent, now: now))
        precondition(!replayGuard.accept(nonce: opened.nonce, sent: opened.sent, now: now.addingTimeInterval(60)), "Replay must be refused")
        precondition(!replayGuard.accept(nonce: Data([1, 2, 3]), sent: now.addingTimeInterval(-21 * 60), now: now), "Stale packet must be refused")
        precondition(replayGuard.accept(nonce: Data([1, 2, 3]), sent: now.addingTimeInterval(-5 * 60), now: now), "A queued background upload within the window is fine")
        print("PASS: encrypted pairing, sealed readings, tamper, wrong-key and replay rejection")

        // Alerts: once per sustained episode, re-arm 5 BPM inside, 30 min cooldown.
        let suite = "pulse-alert-checks-\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        prefs.highAlert = true; prefs.lowAlert = true
        prefs.highLimit = 120; prefs.lowLimit = 45; prefs.sustainMinutes = 5
        let alerts = HeartAlerts(prefs: prefs)
        var fired: [String] = []
        alerts.post = { kind, limit, _ in fired.append("\(kind == .high ? "high" : "low")\(limit)") }
        let t0 = now.timeIntervalSince1970
        var series: [TrendPoint] = []
        func add(_ offset: TimeInterval, _ bpm: Int) {
            series.append(TrendPoint(t: t0 + offset, bpm: bpm))
            alerts.evaluate(points: series, now: Date(timeIntervalSince1970: t0 + offset + 2))
        }
        for i in 0..<24 { add(Double(i) * 10, 130) }            // 4 min above: not yet
        precondition(fired.isEmpty, "Must wait for the sustain time")
        for i in 24..<40 { add(Double(i) * 10, 131) }           // passes 5 min
        precondition(fired == ["high120"], "One alert once sustained")
        for i in 40..<60 { add(Double(i) * 10, 132) }
        precondition(fired.count == 1, "No repeats within an episode")
        add(600, 117)                                           // inside, but not by 5: stays armed off
        for i in 61..<100 { add(Double(i) * 10, 135) }
        precondition(fired.count == 1, "Needs to come back 5 BPM inside before re-arming")
        add(1000, 110)                                          // re-armed
        for i in 101..<140 { add(Double(i) * 10, 135) }         // sustained again, but < 30 min since alert
        precondition(fired.count == 1, "Cooldown blocks a second alert within 30 minutes")
        add(2400, 100)
        for i in 0..<40 { add(2410 + Double(i) * 10, 140) }     // > 30 min later
        precondition(fired.count == 2, "A new episode after the cooldown alerts again")
        // Sparse background readings: one reading past the limit isn't enough, two are.
        let sparse = HeartAlerts(prefs: prefs)
        var sparseFired = 0
        sparse.post = { _, _, _ in sparseFired += 1 }
        let p1 = [TrendPoint(t: t0, bpm: 70), TrendPoint(t: t0 + 900, bpm: 128)]
        sparse.evaluate(points: p1, now: Date(timeIntervalSince1970: t0 + 905))
        precondition(sparseFired == 0)
        sparse.evaluate(points: p1 + [TrendPoint(t: t0 + 1800, bpm: 126)], now: Date(timeIntervalSince1970: t0 + 1805))
        precondition(sparseFired == 1, "Two background readings in a row past the limit alert")
        // Stale data never alerts; low alerts work the same way.
        let stale = HeartAlerts(prefs: prefs)
        var staleFired = 0
        stale.post = { _, _, _ in staleFired += 1 }
        stale.evaluate(points: [TrendPoint(t: t0, bpm: 150), TrendPoint(t: t0 + 600, bpm: 150)],
                       now: Date(timeIntervalSince1970: t0 + 600 + 21 * 60))
        precondition(staleFired == 0, "Old readings must not alert")
        var lowFired: [String] = []
        let lowAlerts = HeartAlerts(prefs: prefs)
        lowAlerts.post = { kind, limit, _ in lowFired.append("\(kind == .high ? "high" : "low")\(limit)") }
        lowAlerts.evaluate(points: [TrendPoint(t: t0, bpm: 42), TrendPoint(t: t0 + 400, bpm: 41)],
                           now: Date(timeIntervalSince1970: t0 + 402))
        precondition(lowFired == ["low45"])
        precondition(prefs.zone(for: 121) == .high && prefs.zone(for: 44) == .low && prefs.zone(for: 80) == .normal)
        UserDefaults().removePersistentDomain(forName: suite)
        print("PASS: alerts once per sustained episode, re-arm, cooldown, sparse and stale readings")

        // Connection health: red only for things that need fixing.
        func health(_ state: ServerState = .listening, responding: Bool = true, paired: Bool = true,
                    contact: TimeInterval? = -60, rejected: TimeInterval? = nil,
                    contactAddress: String? = "192.168.1.8", address: String? = "192.168.1.8") -> ConnectionHealth.Level {
            ConnectionHealth.evaluate(serverState: state, receiverResponding: responding, hasPairedWatch: paired,
                                      lastContact: contact.map { now.addingTimeInterval($0) },
                                      lastRejected: rejected.map { now.addingTimeInterval($0) },
                                      contactAddress: contactAddress, currentAddress: address, now: now).level
        }
        precondition(health() == .good, "Recent check-in is green")
        precondition(health(contact: -19 * 60) == .good)
        precondition(health(contact: -25 * 60) == .warning, "Quiet for 20+ minutes is yellow")
        precondition(health(contact: -9 * 3600) == .warning, "A night off the wrist stays yellow, not red")
        precondition(health(contact: nil) == .warning, "Paired but no check-in yet is yellow")
        precondition(health(address: "192.168.1.23") == .warning, "Changed Mac address is yellow")
        precondition(health(.stopped) == .problem && health(.failed("x")) == .problem && health(.waitingPermission("x")) == .problem)
        precondition(health(responding: false) == .problem, "Receiver not answering is red")
        precondition(health(paired: false) == .problem, "No paired Watch is red")
        precondition(health(contact: -600, rejected: -30) == .problem, "Old pairing in use is red")
        precondition(health(contact: -10, rejected: -30) == .good, "A good check-in after a rejection clears it")
        print("PASS: connection health levels")

        // 30-day history: one bar per calendar day, weighted counts, old data pruned.
        let calendar = Calendar.current
        let today10 = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        let monthHistory = TrendHistory(url: nil)
        monthHistory.insert([
            TrendPoint(t: today10.timeIntervalSince1970, bpm: 70),
            TrendPoint(t: today10.timeIntervalSince1970 + 60, bpm: 90),
            TrendPoint(t: today10.timeIntervalSince1970 + 120, bpm: 80),
            TrendPoint(t: calendar.date(byAdding: .day, value: -2, to: today10)!.timeIntervalSince1970, bpm: 60),
            TrendPoint(t: calendar.date(byAdding: .day, value: -20, to: today10)!.timeIntervalSince1970, bpm: 65),
            TrendPoint(t: calendar.date(byAdding: .day, value: -40, to: today10)!.timeIntervalSince1970, bpm: 99),
        ])
        precondition(!monthHistory.points.contains { $0.bpm == 99 }, "Readings older than 31 days are pruned")
        let laterToday = today10.addingTimeInterval(3600)
        let week = monthHistory.dayBuckets(days: 7, endingAt: laterToday)
        precondition(week.count == 2 && week.last!.min == 70 && week.last!.max == 90 && week.last!.count == 3)
        precondition(week.allSatisfy { calendar.startOfDay(for: $0.start) == $0.start }, "Bars start at midnight")
        precondition(monthHistory.dayBuckets(days: 30, endingAt: laterToday).count == 3, "30D includes 20 days ago")
        print("PASS: 30-day history and daily bars")
        print("PASS: pairing number encoding, decoding and typo rejection")
        print("PASS: backfilled history, deduplication and trend buckets")
        print("PASS: old/new wire compatibility and background provenance")
        print("PASS: duplicate/out-of-order delivery and honest measurement age")
        print("PASS: complication expiry and future timestamp handling")
    }
}
