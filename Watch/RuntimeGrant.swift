import Foundation

/// A few seconds of running time requested from watchOS, for work started
/// outside a background task (HealthKit observer callbacks). Without it the
/// app can be suspended mid-query the moment its other work ends.
///
/// `ProcessInfo.performExpiringActivity` calls its block on a background
/// queue with `expired == false` when time is granted; the activity lasts
/// while that block runs, so it waits until `end()` (or 25 s). If watchOS
/// needs the time back it calls the block again with `expired == true`, and
/// the registered handler cancels the work.
final class RuntimeGrant: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var ended = false
    private var expired = false
    private var expireHandler: (@Sendable () -> Void)?
    private var grantedAt: Date?

    static func begin(reason: String) -> RuntimeGrant {
        let grant = RuntimeGrant()
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired {
                grant.expire()
                return
            }
            grant.markGranted()
            _ = grant.finished.wait(timeout: .now() + 25)
        }
        return grant
    }

    /// Called when watchOS takes the time back (immediately if it already has).
    func onExpire(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if expired {
            lock.unlock()
            handler()
            return
        }
        expireHandler = handler
        lock.unlock()
    }

    /// The work is done; release the extra time.
    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        if let grantedAt {
            PassiveTrace.log("runtime.released", ["held": String(format: "%.1f", Date().timeIntervalSince(grantedAt))])
        }
        finished.signal()
    }

    private func markGranted() {
        lock.lock()
        grantedAt = Date()
        lock.unlock()
        PassiveTrace.log("runtime.granted")
    }

    private func expire() {
        lock.lock()
        expired = true
        let handler = expireHandler
        expireHandler = nil
        let wasEnded = ended
        lock.unlock()
        PassiveTrace.log("runtime.expired", ["workDone": String(wasEnded)])
        handler?()
        finished.signal()
    }
}
