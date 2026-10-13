import CryptoKit
import Foundation

public enum FileChangeKind: String, Codable, Sendable, CaseIterable {
    case added
    case grown
    case shrunk
    case removed
    case moved
    case replaced
    case metadataOnly
    case firstObserved
}

/// How trustworthy a change's measurement is — independent of any attribution.
public enum MeasurementState: String, Codable, Sendable {
    case measured
    case beforeUnknown
    case coverageGap
    case unstable
    case quotaLimited
}

/// When the change actually happened, to the precision we can honestly claim.
public enum TimingPrecision: String, Codable, Sendable {
    case liveHintWindow
    case scanWindow
    case recoveryWindow
}

/// One concrete file-level change. `deltaAllocated` is `nil` unless both ends
/// were measured under the same accounting; before/after allocated are `nil`
/// when unknown — never coerced to 0.
public struct FileChange: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let scanID: UUID?
    public let pathBefore: String?
    public let pathAfter: String?
    public let identityBefore: String?
    public let identityAfter: String?
    public let kind: FileChangeKind
    public let windowStart: Date
    public let windowEnd: Date
    public let observedAt: Date
    public let beforeLogical: Int64?
    public let afterLogical: Int64?
    public let beforeAllocated: Int64?
    public let afterAllocated: Int64?
    public let deltaAllocated: Int64?
    public let measurement: MeasurementState
    public let timing: TimingPrecision
    public let evidenceVersion: Int

    public init(
        id: UUID,
        rootID: UUID,
        scanID: UUID?,
        pathBefore: String?,
        pathAfter: String?,
        identityBefore: String?,
        identityAfter: String?,
        kind: FileChangeKind,
        windowStart: Date,
        windowEnd: Date,
        observedAt: Date,
        beforeLogical: Int64?,
        afterLogical: Int64?,
        beforeAllocated: Int64?,
        afterAllocated: Int64?,
        deltaAllocated: Int64?,
        measurement: MeasurementState,
        timing: TimingPrecision,
        evidenceVersion: Int
    ) {
        self.id = id
        self.rootID = rootID
        self.scanID = scanID
        self.pathBefore = pathBefore
        self.pathAfter = pathAfter
        self.identityBefore = identityBefore
        self.identityAfter = identityAfter
        self.kind = kind
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.observedAt = observedAt
        self.beforeLogical = beforeLogical
        self.afterLogical = afterLogical
        self.beforeAllocated = beforeAllocated
        self.afterAllocated = afterAllocated
        self.deltaAllocated = deltaAllocated
        self.measurement = measurement
        self.timing = timing
        self.evidenceVersion = evidenceVersion
    }

    /// Stable id: re-processing the same hint or scan produces the same change.
    public static func stableID(
        evidenceVersion: Int, rootID: UUID, identityBefore: String?, identityAfter: String?,
        pathBefore: String?, pathAfter: String?, locator: String
    ) -> UUID {
        let key = [
            "filechange-v1", String(evidenceVersion), rootID.uuidString,
            identityBefore ?? "-", identityAfter ?? "-", pathBefore ?? "-", pathAfter ?? "-", locator,
        ].joined(separator: "|")
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

    public var displayPath: String { pathAfter ?? pathBefore ?? "（路径未知）" }
    public var netBytes: Int64? { deltaAllocated }
}
