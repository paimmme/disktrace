import CryptoKit
import Foundation

/// Root state machine (per root, independent of every other root).
public enum RootState: String, Codable, Sendable {
    case pending
    case scanning
    case ready
    case needsRebaseline
    case permissionDenied
    case quotaLimited
    case paused
    case unavailable
}

public struct MonitoredRoot: Sendable, Hashable {
    public let id: UUID
    public let canonicalPath: String
    public let volumeID: String?
    public let enabled: Bool
    public let configRevision: Int

    public init(id: UUID, canonicalPath: String, volumeID: String?, enabled: Bool, configRevision: Int) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.volumeID = volumeID
        self.enabled = enabled
        self.configRevision = configRevision
    }

    /// Stable id: `root-v1|canonicalPath`.
    public static func stableID(canonicalPath: String) -> UUID {
        let digest = SHA256.hash(data: Data("root-v1|\(canonicalPath)".utf8))
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

public struct RootHealth: Sendable, Hashable {
    public let rootID: UUID
    public let activeScanID: UUID?
    public let state: RootState
    public let lastSuccessAt: Date?
    public let nextRetryAt: Date?
    public let inventoryCoverage: String
    public let limitationKind: RootLimitationKind?

    public init(
        rootID: UUID, activeScanID: UUID?, state: RootState, lastSuccessAt: Date?,
        nextRetryAt: Date?, inventoryCoverage: String, limitationKind: RootLimitationKind? = nil
    ) {
        self.rootID = rootID
        self.activeScanID = activeScanID
        self.state = state
        self.lastSuccessAt = lastSuccessAt
        self.nextRetryAt = nextRetryAt
        self.inventoryCoverage = inventoryCoverage
        self.limitationKind = limitationKind
    }
}

/// Result of publishing a scan generation.
public struct PublishResult: Sendable {
    public enum State: String, Sendable {
        case completed
        case baseline  // first complete scan: establishes baseline, no changes
        case needsRebaseline
    }
    public let state: State
    public let fileChanges: [FileChange]
    public let directoryDeltas: [DirectoryDelta]
    public init(state: State, fileChanges: [FileChange], directoryDeltas: [DirectoryDelta]) {
        self.state = state
        self.fileChanges = fileChanges
        self.directoryDeltas = directoryDeltas
    }
}
