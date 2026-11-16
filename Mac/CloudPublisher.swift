import Foundation
import Observation

/// Keeps this Mac's address and access key current in the user's private
/// iCloud database, so the Watch pairs without typing and finds the Mac
/// again after its address changes.
@MainActor
@Observable
final class CloudPublisher {
    enum State: Equatable {
        case idle
        case publishing
        case published(Date)
        case signedOut
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var published: (address: String, token: String)?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttempt = Date.distantPast

    /// Cheap to call often: does nothing unless something changed.
    func update(address: String?, hostname: String?, token: String) {
        guard CloudPairing.isEnabled, let address, !inFlight else { return }
        if let published, published.address == address, published.token == token { return }
        guard Date().timeIntervalSince(lastAttempt) >= 30 else { return }
        inFlight = true
        lastAttempt = Date()
        if published == nil { state = .publishing }
        Task {
            defer { inFlight = false }
            switch await CloudPairing.availability() {
            case .signedOut:
                state = .signedOut
                return
            case .unavailable(let message):
                state = .failed(message)
                return
            case .available:
                break
            }
            do {
                try await CloudPairing.publish(address: address, hostname: hostname, token: token)
                published = (address, token)
                state = .published(Date())
                IngestLog.note("cloud-endpoint-published")
            } catch {
                state = .failed(error.localizedDescription)
                IngestLog.note("cloud-publish-failed")
            }
        }
    }
}
