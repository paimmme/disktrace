import CryptoKit
import Foundation

/// What *kind* of path grew — never who wrote it. Segment-matched, never a
/// substring, so `my_node_modules_backup` does not match `node_modules`.
public enum ReasonCategory: String, Codable, Sendable, CaseIterable {
    case dependencies
    case buildOutputs
    case modelCache
    case sessionArtifacts
    case temporaryFiles
    case downloadsFolder
    case mixed
    case unknown
}

public enum EventAttributionClass: String, Codable, Sendable {
    case unknown
    case userConfirmed
    case agentProbable
    case agentConfirmed
}

public enum EventStatus: String, Codable, Sendable {
    case collecting
    case ready
    case partial
    case detailExpired
}

public enum TaskLinkState: String, Codable, Sendable {
    case timeOnly
    case pathCandidate
    case ambiguous
    case userConfirmed
    case verifiedWriter
}

/// A user-understandable storage event: a scope that grew (or shrank) in a
/// fixed time bucket, with its file details and any candidate tasks.
public struct StorageEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let scopePath: String
    public let windowStart: Date
    public let windowEnd: Date
    public let grossAddedBytes: Int64?
    public let grossRemovedBytes: Int64?
    public let netBytes: Int64?
    public let measurement: MeasurementState
    public let reasonCategory: ReasonCategory
    public let attributionClass: EventAttributionClass
    public let candidateCount: Int
    /// Measured file bytes that got no task candidate — NOT "unknown volume space".
    public let unassignedBytes: Int64?
    public let status: EventStatus
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, rootID: UUID, scopePath: String, windowStart: Date, windowEnd: Date,
        grossAddedBytes: Int64?, grossRemovedBytes: Int64?, netBytes: Int64?,
        measurement: MeasurementState, reasonCategory: ReasonCategory,
        attributionClass: EventAttributionClass, candidateCount: Int, unassignedBytes: Int64?,
        status: EventStatus, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.rootID = rootID
        self.scopePath = scopePath
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.grossAddedBytes = grossAddedBytes
        self.grossRemovedBytes = grossRemovedBytes
        self.netBytes = netBytes
        self.measurement = measurement
        self.reasonCategory = reasonCategory
        self.attributionClass = attributionClass
        self.candidateCount = candidateCount
        self.unassignedBytes = unassignedBytes
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `storage-v1|rootID|scopePath|bucketStart|configRevision`.
    public static func stableID(
        rootID: UUID, scopePath: String, bucketStart: Date, configRevision: Int
    ) -> UUID {
        let bucket = Int64(bucketStart.timeIntervalSince1970)
        let key = "storage-v1|\(rootID.uuidString)|\(scopePath)|\(bucket)|\(configRevision)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]))
    }
}

public struct TaskLink: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(eventID.uuidString)|\(activityID.uuidString)|\(algorithmVersion)" }
    public let eventID: UUID
    public let activityID: UUID
    public let state: TaskLinkState
    public let basis: String
    /// Measured net change of the candidate files — never "proven agent bytes".
    public let candidateBytes: Int64?
    public let algorithmVersion: String
    public let limitation: String

    public init(
        eventID: UUID, activityID: UUID, state: TaskLinkState, basis: String,
        candidateBytes: Int64?, algorithmVersion: String, limitation: String
    ) {
        self.eventID = eventID
        self.activityID = activityID
        self.state = state
        self.basis = basis
        self.candidateBytes = candidateBytes
        self.algorithmVersion = algorithmVersion
        self.limitation = limitation
    }
}

public enum PresenceResult: String, Codable, Sendable {
    case present
    case replaced
    case missing
    case unknown  // not yet checked / no permission
}

public struct PresenceCheck: Codable, Sendable, Hashable {
    public let changeID: UUID
    public let scheduledAt: Date
    public let checkedAt: Date?
    public let result: PresenceResult
    public let currentIdentity: String?
    public let currentAllocated: Int64?

    public init(
        changeID: UUID, scheduledAt: Date, checkedAt: Date?, result: PresenceResult,
        currentIdentity: String?, currentAllocated: Int64?
    ) {
        self.changeID = changeID
        self.scheduledAt = scheduledAt
        self.checkedAt = checkedAt
        self.result = result
        self.currentIdentity = currentIdentity
        self.currentAllocated = currentAllocated
    }
}

public struct EventFeedback: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let eventID: UUID
    public let kind: String  // "confirmUser"
    public let createdAt: Date
    public let revokedAt: Date?

    public init(id: UUID = UUID(), eventID: UUID, kind: String, createdAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.eventID = eventID
        self.kind = kind
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }
}
