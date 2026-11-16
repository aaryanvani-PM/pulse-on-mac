import Foundation
import HealthKit
import Observation

/// HealthKit session manager.
///
/// Deliberate design decisions (validated against Apple's requirements):
/// - `.other` activity type: this is a sensor-activation session for live
///   heart rate at a desk, NOT a claim of exercise. Apple's only supported
///   mechanism for ~1 Hz live HR delivery is an active HKWorkoutSession.
/// - The workout is always discarded (`discardWorkout`): nothing is written
///   to Health, no Activity rings impact.
/// - Heart-rate readings are consumed with their true HealthKit sample
///   timestamps; missing readings are surfaced as "missing" events.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    enum State: Equatable {
        case idle, starting, running, failed(String)
    }

    private(set) var state: State = .idle
    private(set) var bpm: Int?
    private(set) var lastSampleDate: Date?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var hrQuery: HKAnchoredObjectQuery?
    private var transmitTask: Task<Void, Never>?
    private var lastSentSampleDate: Date?
    private var lastMissingSentDate: Date?
    private var noSampleNoticeSent = false
    private var workoutStartDate: Date?
    private let link: LinkClient

    init(link: LinkClient) {
        self.link = link
        super.init()
    }

    func toggle() {
        switch state {
        case .idle:
            Task { await start() }
        case .starting:
            break
        case .running:
            stop()
        case .failed:
            stop()
            Task { await start() }
        }
    }

    func start() async {
        guard state == .idle else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed("Health data is not available on this device.")
            return
        }
        state = .starting
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKWorkoutType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
        } catch {
            state = .failed("Health authorization was denied.")
            return
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            self.session = session
            self.builder = builder
            workoutStartDate = Date()
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        // A failed start must not leave the query and
                        // transmit loop running against a dead session.
                        self.teardown(discardWorkout: true)
                        self.state = .failed(error.localizedDescription)
                    } else {
                        self.state = .running
                    }
                }
            }
            startHeartRateQuery()
            startTransmitLoop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        teardown(discardWorkout: true)
        state = .idle
        // No end event is sent: the Mac's staleness windows (6 s / 15 s)
        // naturally flip the status to Stale once traffic stops.
    }

    /// Cancels the transmit loop, stops the query and discards the
    /// session — shared by the clean stop and every failure path, so a
    /// failure never leaves the loop or query running against a dead
    /// session.
    private func teardown(discardWorkout: Bool) {
        transmitTask?.cancel()
        transmitTask = nil
        if let query = hrQuery {
            healthStore.stop(query)
        }
        hrQuery = nil
        if discardWorkout {
            let builder = self.builder
            session?.end()
            builder?.endCollection(withEnd: Date()) { _, _ in
                builder?.discardWorkout()
            }
        }
        session = nil
        self.builder = nil
        bpm = nil
        lastSampleDate = nil
        lastSentSampleDate = nil
        lastMissingSentDate = nil
        noSampleNoticeSent = false
        workoutStartDate = nil
    }

    // MARK: - Heart-rate delivery

    private func startHeartRateQuery() {
        let heartRateType = HKQuantityType(.heartRate)
        // Only samples recorded from session start onward: without this
        // filter, the anchored query's initial run replays the newest
        // HISTORICAL sample as if it were live.
        let start = workoutStartDate ?? Date()
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: nil, options: .strictStartDate
        )
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            Self.processSamples(samples, manager: self)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            Self.processSamples(samples, manager: self)
        }
        hrQuery = query
        healthStore.execute(query)
    }

    private nonisolated static func processSamples(_ samples: [HKSample]?, manager: WorkoutManager?) {
        guard let samples, !samples.isEmpty else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let newest = samples
            .compactMap({ $0 as? HKQuantitySample })
            .max(by: { $0.startDate < $1.startDate }) else { return }
        let value = Int(newest.quantity.doubleValue(for: unit).rounded())
        let date = newest.startDate
        Task { @MainActor [weak manager] in
            manager?.bpm = value
            manager?.lastSampleDate = date
        }
    }

    // MARK: - Transmit loop (one POST per 2 s, newest sample wins)

    private func startTransmitLoop() {
        transmitTask?.cancel()
        transmitTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.transmitOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func transmitOnce() async {
        let now = Date()
        if let lastSample = lastSampleDate {
            if lastSample != lastSentSampleDate, let bpm {
                lastSentSampleDate = lastSample
                lastMissingSentDate = nil
                noSampleNoticeSent = false
                await link.send(
                    WatchPacket(
                        event: PacketEvent.heartRate,
                        bpm: bpm,
                        sampleTs: lastSample.timeIntervalSince1970,
                        mode: .live
                    )
                )
            } else if now.timeIntervalSince(lastSample) > 15, lastMissingSentDate != lastSample {
                // Session running but the sensor stopped producing readings
                // (watch off wrist, poor contact). Tell the Mac explicitly.
                lastMissingSentDate = lastSample
                await link.send(
                    WatchPacket(
                        event: PacketEvent.missing,
                        bpm: nil,
                        sampleTs: lastSample.timeIntervalSince1970,
                        mode: .live
                    )
                )
            }
        } else if let start = workoutStartDate,
                  now.timeIntervalSince(start) > 20,
                  !noSampleNoticeSent {
            noSampleNoticeSent = true
            await link.send(
                WatchPacket(
                    event: PacketEvent.missing,
                    bpm: nil,
                    sampleTs: nil,
                    mode: .live
                )
            )
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .stopped {
            Task { @MainActor [weak self] in
                self?.handleSessionEnded()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            // Full teardown on failure: the query and transmit loop must
            // not outlive the session they feed.
            self?.teardown(discardWorkout: true)
            self?.state = .failed(message)
        }
    }

    private func handleSessionEnded() {
        guard state == .running || state == .starting else { return }
        stop()
    }
}
