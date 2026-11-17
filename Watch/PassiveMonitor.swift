import Foundation
import HealthKit
import Observation
import WatchKit
import WidgetKit

/// Relays existing HealthKit readings. Neither observer delivery nor scheduled
/// refresh forces a sensor measurement or guarantees an execution interval.
@MainActor
@Observable
final class PassiveMonitor {
    struct Reading: Sendable {
        let bpm: Int
        let ts: TimeInterval
        /// Older Watch readings not yet confirmed by the Mac (newest first).
        var history: [WatchPacket.HistoryPoint] = []
    }

    /// Bounds the upload body; at rest this covers many hours of samples.
    private static let maxHistoryPoints = 200

    private struct CompletionBox: @unchecked Sendable {
        let run: () -> Void
    }

    private let healthStore = HKHealthStore()
    private let link: LinkClient
    private let isContinuousActive: @MainActor () -> Bool
    private var observerQuery: HKObserverQuery?
    private var isRegistering = false
    private var isSyncing = false
    /// When the running sync started, and which one it is. watchOS can
    /// suspend the app mid-query at the end of a wake; that frozen sync must
    /// not block the next wake (seen on device: a refresh skipped 16 minutes
    /// later because of it).
    private var syncStartedAt: Date?
    private var syncToken: UUID?
    /// A real sync takes seconds; one older than this was frozen.
    /// (A foreground send that retries the network can take most of a minute.)
    private static let staleSyncAfter: TimeInterval = 120
    private var desiredEnabled = false
    private var observerCallbacks = 0
    private(set) var isRegistered = false
    private(set) var lastReading: Reading?
    private(set) var lastSyncAt: Date?
    private(set) var lastStatusText: String?
    private(set) var diagnostics = PassiveDiagnostics.load()

    init(link: LinkClient, isContinuousActive: @escaping @MainActor () -> Bool) {
        self.link = link
        self.isContinuousActive = isContinuousActive
    }

    /// Install synchronously at process launch, before any authorization await.
    /// Saved Health permission is reused; background launches never prompt.
    func restoreAtLaunch() {
        CredentialStore.prepareForBackground()
        BackgroundUploader.shared.restore()
        desiredEnabled = BackgroundRefresh.isEnabled
        let paired = CredentialStore.current != nil
        PassiveTrace.event("launch", ["enabled": String(desiredEnabled), "paired": String(paired)])
        BackgroundUploader.shared.traceOutstanding()
        guard desiredEnabled, paired else { return }
        installObserver()
        BackgroundRefresh.scheduleIfNeeded()
    }

    /// Called only from foreground UI to request permission and arm delivery.
    func syncState(enabled: Bool) async {
        desiredEnabled = enabled
        guard enabled, CredentialStore.current != nil else {
            await disable()
            return
        }
        guard !isRegistering else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isRegistering = true
        defer { isRegistering = false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [HKQuantityType(.heartRate)])
            guard desiredEnabled, CredentialStore.current != nil else { return }
            installObserver()
            // Immediate is a request, not an interval guarantee. watchOS
            // may throttle ordinary heart-rate quantities and shares wake budgets.
            try await healthStore.enableBackgroundDelivery(for: HKQuantityType(.heartRate), frequency: .immediate)
            guard desiredEnabled, CredentialStore.current != nil else {
                await disable()
                return
            }
            BackgroundRefresh.scheduleIfNeeded()
            lastStatusText = "Ready · add Heart Rate to your active watch face"
        } catch {
            lastStatusText = "Setup failed: \(error.localizedDescription)"
        }
    }

    private func installObserver() {
        guard observerQuery == nil else { return }
        let query = HKObserverQuery(sampleType: HKQuantityType(.heartRate), predicate: nil) { [weak self] _, completionHandler, error in
            let completion = CompletionBox(run: completionHandler)
            let errorText = error?.localizedDescription
            // A HealthKit callback carries no guaranteed runtime: it often
            // lands as a wake is ending, and watchOS then froze the app
            // mid-query (seen on device: a 16-minute query, reading stranded).
            // Ask for extra time first, synchronously, before anything else.
            let runtime = RuntimeGrant.begin(reason: "Send the new heart-rate reading to the Mac")
            Task { @MainActor [weak self] in
                // Completion is called on every path, including query errors.
                defer {
                    completion.run()
                    runtime.end()
                }
                guard let self else { return }
                // HealthKit always calls the handler once when the query is
                // first executed. That call is "the process started", not
                // "a new sample was saved"; the trace keeps them apart.
                self.observerCallbacks += 1
                var fields = ["n": String(self.observerCallbacks)]
                if let errorText { fields["error"] = errorText }
                PassiveTrace.event("observer.callback", fields)
                if let errorText {
                    self.lastStatusText = "Observer failed: \(errorText)"
                    return
                }
                // Keep observer processing inside the short runtime budget.
                let work = Task { await self.sync(trigger: .observer) }
                // If watchOS takes the extra time back, stop cleanly rather
                // than freeze mid-query holding the sync lock.
                runtime.onExpire { work.cancel() }
                // A background wake has only seconds. On screen there is
                // room for an interactive send and, if needed, a search.
                let limit: Duration = Self.appState == .background ? .seconds(20) : .seconds(90)
                let timeout = Task {
                    try? await Task.sleep(for: limit)
                    if !Task.isCancelled { work.cancel() }
                }
                await work.value
                timeout.cancel()
            }
        }
        observerQuery = query
        healthStore.execute(query)
        isRegistered = true
    }

    private func disable() async {
        if let observerQuery { healthStore.stop(observerQuery) }
        observerQuery = nil
        isRegistered = false
        BackgroundRefresh.clearSchedule()
        await BackgroundUploader.shared.cancelAll()
        ComplicationCache.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: ComplicationCache.kind)
        try? await healthStore.disableBackgroundDelivery(for: HKQuantityType(.heartRate))
    }

    func unpair() async {
        desiredEnabled = false
        await disable()
    }

    func syncNow() async { await sync(trigger: .foreground) }

    /// SwiftUI completes the OS refresh task when this returns. Reschedule
    /// first, so cancellation or suspension cannot break the refresh chain.
    func scheduledRefresh() async {
        PassiveTrace.event("refresh.fired")
        BackgroundRefresh.clearSchedule()
        BackgroundRefresh.scheduleIfNeeded()
        // The refresh is the one wake with guaranteed runtime. If a callback
        // sync is mid-flight, give it a moment instead of skipping this
        // wake; if it doesn't finish, run anyway (it counts as stale below).
        var waited = 0
        while isSyncing, waited < 16 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        if waited > 0 { PassiveTrace.event("refresh.waitedForSync", ["ms": String(waited * 500)]) }
        await sync(trigger: .scheduledRefresh, forceIfBusy: waited >= 16)
    }

    /// Runs in the wake watchOS grants when a background upload finishes.
    /// If that upload was confirmed and HealthKit already holds a newer
    /// sample, queue it now instead of waiting for the next observer wake.
    /// Failures do not chain: a down Mac must not cause a retry loop.
    func followUpAfterUpload() async {
        guard BackgroundUploader.shared.consumeRecentSuccess() else { return }
        await sync(trigger: .followUp)
    }

    private func sync(trigger: WatchPacket.SyncTrigger, forceIfBusy: Bool = false) async {
        let state = Self.appState
        let op = PassiveTrace.newOp()
        PassiveTrace.event("sync.begin", op: op, ["trigger": trigger.rawValue])
        // A long-lived process is not relaunched between wakes; without this
        // an elapsed refresh request would never be replaced.
        BackgroundRefresh.scheduleIfNeeded()
        diagnostics = PassiveDiagnostics.load()
        diagnostics.recordWake(trigger: trigger, state: state)
        var outcome = "Wake received"
        defer {
            PassiveTrace.event("sync.end", op: op, ["outcome": outcome])
            if state == .background, trigger != .foreground {
                // Reload: a transfer delegate may have updated counters while
                // this async query was suspended.
                diagnostics = PassiveDiagnostics.load()
                diagnostics.recordOutcome(outcome)
            }
        }
        guard BackgroundRefresh.isEnabled, desiredEnabled, CredentialStore.current != nil else {
            outcome = "Skipped: disabled or pairing inaccessible"
            return
        }
        let lockIsStale = isSyncing && (forceIfBusy || Date().timeIntervalSince(syncStartedAt ?? .distantPast) > Self.staleSyncAfter)
        guard !isContinuousActive(), !isSyncing || lockIsStale, !Task.isCancelled else {
            outcome = "Skipped: another sync/session active or canceled"
            return
        }
        if lockIsStale {
            PassiveTrace.event("sync.staleLockReplaced", op: op,
                               ["age": String(Int(Date().timeIntervalSince(syncStartedAt ?? Date())))])
        }
        let token = UUID()
        syncToken = token
        isSyncing = true
        syncStartedAt = Date()
        // Only the newest sync releases the lock; a frozen one that resumes
        // later must not clear a lock a newer sync now holds.
        defer {
            if syncToken == token {
                isSyncing = false
                syncStartedAt = nil
            }
        }
        do {
            // One bounded newest-sample query, never a full-history baseline.
            // No persistent anchor is needed when only the newest value is sent.
            guard let reading = try await fetchNewestReading(op: op) else {
                outcome = "No readable Watch sample · check permission or lock state"
                lastStatusText = "No recent reading · check Heart Rate permission"
                return
            }
            try Task.checkCancellation()
            guard BackgroundRefresh.isEnabled, desiredEnabled, CredentialStore.current != nil,
                  !isContinuousActive() else { return }
            lastReading = reading
            if ComplicationCache.save(bpm: reading.bpm, measuredAt: Date(timeIntervalSince1970: reading.ts)) {
                WidgetCenter.shared.reloadTimelines(ofKind: ComplicationCache.kind)
            }
            let deliveredTs = UserDefaults.standard.double(forKey: "passiveSync.deliveredTs.v2")
            PassiveTrace.event("sync.checkpoint", op: op, [
                "sampleTs": PassiveTrace.stamp(reading.ts),
                "deliveredTs": PassiveTrace.stamp(deliveredTs),
                "newer": String(reading.ts > deliveredTs),
            ])
            // Background retries a failed delivery on the next wake. A refresh
            // with no newer reading still sends a receipt for diagnostic proof.
            if trigger == .observer || trigger == .followUp, reading.ts <= deliveredTs {
                outcome = "No newer persisted sample to send"
                return
            }
            var packet = WatchPacket(event: PacketEvent.heartRate, bpm: reading.bpm,
                                     sampleTs: reading.ts, mode: .passive)
            packet.trigger = trigger
            packet.appState = Self.appState
            packet.op = op
            if !reading.history.isEmpty { packet.history = reading.history }
            // An observer callback while the app is on screen (launch, re-arm)
            // has full runtime: send interactively. The system-managed
            // background transfer is for wakes without that runtime.
            if trigger != .foreground, packet.appState != .active {
                try await BackgroundUploader.shared.enqueue(packet)
                outcome = PassiveDiagnostics.load().lastBackgroundOutcome ?? "Background upload queued"
                lastStatusText = outcome
                return
            }
            packet.queuedTs = Date().timeIntervalSince1970
            let delivered = await sendForeground(packet)
            PassiveTrace.event("foreground.send", op: op, ["delivered": String(delivered)])
            guard !Task.isCancelled else { return }
            if delivered {
                UserDefaults.standard.set(max(deliveredTs, reading.ts), forKey: "passiveSync.deliveredTs.v2")
                lastSyncAt = Date()
                diagnostics.recordDelivery(trigger: trigger, state: packet.appState ?? state)
                lastStatusText = "Mac received · \(reading.bpm) BPM"
            } else {
                let detail = await link.lastFailureMessage
                lastStatusText = "Send failed: \(detail ?? "will retry at next refresh")"
            }
            outcome = delivered ? "Foreground send confirmed" : "Foreground send failed"
        } catch is CancellationError {
            outcome = "Refresh canceled or expired"
            lastStatusText = "Refresh expired · will retry later"
        } catch {
            outcome = "Read/queue failed: \(error.localizedDescription)"
            lastStatusText = "Read failed: \(error.localizedDescription)"
        }
    }

    private static var appState: WatchPacket.AppState {
        switch WKApplication.shared().applicationState {
        case .active: return .active
        case .inactive: return .inactive
        default: return .background
        }
    }

    private func sendForeground(_ packet: WatchPacket) async -> Bool {
        for attempt in 0..<3 {
            if Task.isCancelled { return false }
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return false }
            }
            if await link.send(packet, loud: false) { return true }
        }
        return false
    }

    private func fetchNewestReading(op: String) async throws -> Reading? {
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-86400), end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 20
        )
        let started = Date()
        let samples: [HKQuantitySample]
        do {
            samples = try await descriptor.result(for: healthStore)
        } catch {
            let nsError = error as NSError
            PassiveTrace.event("query.error", op: op, ["error": "\(nsError.domain) \(nsError.code)"])
            throw error
        }
        // Ignore manual entries and external sensor imports; this is Watch HR.
        let accepted = samples.firstIndex(where: {
            !($0.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false) &&
            ($0.sourceRevision.productType?.hasPrefix("Watch") == true ||
             $0.device?.model?.contains("Watch") == true)
        })
        var fields = ["count": String(samples.count),
                      "ms": String(Int(Date().timeIntervalSince(started) * 1000))]
        // Newest sample before filtering vs. the one the filter accepted:
        // a gap between them means the filter is hiding a newer reading.
        if let newest = samples.first { fields["newestRawTs"] = PassiveTrace.stamp(newest.startDate.timeIntervalSince1970) }
        if let accepted {
            fields["acceptedTs"] = PassiveTrace.stamp(samples[accepted].startDate.timeIntervalSince1970)
            fields["skippedByFilter"] = String(accepted)
        }
        // Spacing of what HealthKit has persisted, newest first (seconds).
        let gaps = zip(samples, samples.dropFirst()).prefix(6).map {
            String(Int($0.startDate.timeIntervalSince($1.startDate)))
        }
        if !gaps.isEmpty { fields["gaps"] = gaps.joined(separator: ",") }
        guard let accepted else {
            PassiveTrace.event("query.result", op: op, fields)
            return nil
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let sample = samples[accepted]
        let value = sample.quantity.doubleValue(for: unit)
        PassiveTrace.event("query.result", op: op, fields)
        guard value.isFinite, (20...250).contains(value) else { return nil }
        let newestTs = sample.startDate.timeIntervalSince1970
        // Second, narrower query only when there is something to backfill:
        // readings older than the newest that the Mac has not confirmed.
        let deliveredTs = UserDefaults.standard.double(forKey: "passiveSync.deliveredTs.v2")
        var history: [WatchPacket.HistoryPoint] = []
        if newestTs > deliveredTs {
            let historyStarted = Date()
            let from = max(deliveredTs + 0.001, Date().timeIntervalSince1970 - 86400)
            let window = HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: from),
                                                     end: sample.startDate, options: .strictStartDate)
            let older = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: window)],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: Self.maxHistoryPoints
            )
            // The newest reading still goes out if this part fails.
            let rows = (try? await older.result(for: healthStore)) ?? []
            history = rows.compactMap {
                let ts = $0.startDate.timeIntervalSince1970
                guard ts > deliveredTs, ts < newestTs,
                      !($0.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false),
                      $0.sourceRevision.productType?.hasPrefix("Watch") == true ||
                      $0.device?.model?.contains("Watch") == true else { return nil }
                let bpm = $0.quantity.doubleValue(for: unit)
                guard bpm.isFinite, (20...250).contains(bpm) else { return nil }
                return WatchPacket.HistoryPoint(t: ts, b: Int(bpm.rounded()))
            }
            PassiveTrace.event("query.history", op: op, [
                "rows": String(rows.count), "kept": String(history.count),
                "ms": String(Int(Date().timeIntervalSince(historyStarted) * 1000)),
            ])
        }
        return Reading(bpm: Int(value.rounded()), ts: newestTs, history: history)
    }
}
