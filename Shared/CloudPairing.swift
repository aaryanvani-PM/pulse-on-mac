#if ICLOUD_PAIRING
import CloudKit
#endif
import Foundation

/// Pairing details only, in the user's PRIVATE iCloud database: where the Mac
/// is on the local network and the access key it accepts. Heart-rate readings
/// never go through iCloud (App Review guideline 5.1.3 forbids storing
/// personal health information there); they travel Watch -> Mac directly.
enum CloudPairing {
    /// Follows the build's bundle prefix (Info.plist key HRAppGroup is
    /// "group.<prefix>.hrlink"), like the App Group does.
    static let containerID: String = {
        let group = Bundle.main.object(forInfoDictionaryKey: "HRAppGroup") as? String ?? ""
        return "iCloud." + (group.hasPrefix("group.") ? String(group.dropFirst(6)) : "hrlink")
    }()

    struct Endpoint: Sendable, Equatable {
        let address: String
        let hostname: String?
        let token: String
        let updatedAt: Date
    }

    enum Availability: Sendable, Equatable {
        case available
        case signedOut
        case unavailable(String)
    }

    #if ICLOUD_PAIRING
    static let isEnabled = true
    private static let recordType = "MacEndpoint"
    private static var recordID: CKRecord.ID { CKRecord.ID(recordName: "mac-endpoint") }
    private static var container: CKContainer { CKContainer(identifier: containerID) }

    static func availability() async -> Availability {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .signedOut
            default: return .unavailable("iCloud is restricted or temporarily unavailable")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Mac side: publish (or replace) this Mac's current endpoint.
    static func publish(address: String, hostname: String?, token: String) async throws {
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["address"] = address
        record["hostname"] = hostname
        record["updatedAt"] = Date()
        // Encrypted field: readable only on the user's own devices.
        record.encryptedValues["token"] = token
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [record], deleting: [], savePolicy: .allKeys
        )
        if case .failure(let error)? = result.saveResults[recordID] { throw error }
    }

    /// Watch side: nil when no Mac has published yet.
    static func fetch() async throws -> Endpoint? {
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let address = record["address"] as? String, !address.isEmpty,
                  let token = record.encryptedValues["token"] as? String, !token.isEmpty else { return nil }
            return Endpoint(address: address, hostname: record["hostname"] as? String, token: token,
                            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
    #else
    /// Built without the iCloud entitlement: touching CloudKit would crash,
    /// so every entry point is inert and manual pairing is used.
    static let isEnabled = false
    static func availability() async -> Availability { .unavailable("not enabled in this build") }
    static func publish(address: String, hostname: String?, token: String) async throws {}
    static func fetch() async throws -> Endpoint? { nil }
    #endif
}
