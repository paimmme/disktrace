import Foundation

public enum AvailabilityStatus: String, Codable, Sendable {
    case available
    case permissionDenied
    case unavailable
}

/// Volume-level time-series fact. Free space, monitored-directory net growth
/// and write I/O bytes are distinct metrics and are never reconciled into one.
public struct VolumeSample: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let volumeID: String
    public let observedAt: Date
    public let freeBytes: Int64
    public let capacityBytes: Int64
    public let status: AvailabilityStatus

    public init(
        id: UUID = UUID(),
        volumeID: String,
        observedAt: Date,
        freeBytes: Int64,
        capacityBytes: Int64,
        status: AvailabilityStatus
    ) {
        self.id = id
        self.volumeID = volumeID
        self.observedAt = observedAt
        self.freeBytes = freeBytes
        self.capacityBytes = capacityBytes
        self.status = status
    }

    public var usedBytes: Int64 { max(0, capacityBytes - freeBytes) }

    public var freeFraction: Double {
        guard capacityBytes > 0 else { return 0 }
        return Double(freeBytes) / Double(capacityBytes)
    }
}

/// How trustworthy the directory measurement is. This is **independent** of
/// attribution confidence: a delta can be perfectly calibrated yet have an
/// entirely unknown source.
public enum CalibrationStatus: String, Codable, Sendable {
    case calibrated
    case pendingBaseline
    case stale
    case coverageGap
}

/// Windowed net change for a normalized directory path.
public struct DirectoryDelta: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let pathID: String
    public let windowStart: Date
    public let windowEnd: Date
    public let deltaAllocatedBytes: Int64
    public let beforeAllocatedBytes: Int64
    public let afterAllocatedBytes: Int64
    public let checkpointID: UInt64
    public let calibration: CalibrationStatus

    public init(
        id: UUID = UUID(),
        pathID: String,
        windowStart: Date,
        windowEnd: Date,
        deltaAllocatedBytes: Int64,
        beforeAllocatedBytes: Int64,
        afterAllocatedBytes: Int64,
        checkpointID: UInt64,
        calibration: CalibrationStatus
    ) {
        self.id = id
        self.pathID = pathID
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.deltaAllocatedBytes = deltaAllocatedBytes
        self.beforeAllocatedBytes = beforeAllocatedBytes
        self.afterAllocatedBytes = afterAllocatedBytes
        self.checkpointID = checkpointID
        self.calibration = calibration
    }

    public var growthBytes: Int64 { max(0, deltaAllocatedBytes) }
}

public enum ChangeFlag: String, Codable, Sendable {
    case created
    case removed
    case renamed
    case modified
    case metadataModified
    case rootChanged
    case mustScanSubdirectories
    case unknown
}

/// A deduplicated filesystem change clue from FSEvents. A hint proves *a path
/// changed*, never who wrote it or how many bytes.
public struct ChangeHint: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let eventID: UInt64
    public let path: String
    public let flag: ChangeFlag
    public let observedAt: Date

    public init(
        id: UUID = UUID(),
        eventID: UInt64,
        path: String,
        flag: ChangeFlag,
        observedAt: Date
    ) {
        self.id = id
        self.eventID = eventID
        self.path = path
        self.flag = flag
        self.observedAt = observedAt
    }
}

/// The unit the alert policy evaluates.
public enum StorageObservation: Sendable, Hashable {
    case volume(VolumeSample)
    case directory(DirectoryDelta)

    public var observedAt: Date {
        switch self {
        case .volume(let sample): return sample.observedAt
        case .directory(let delta): return delta.windowEnd
        }
    }

    public var subjectID: UUID {
        switch self {
        case .volume(let sample): return sample.id
        case .directory(let delta): return delta.id
        }
    }

    public var pathID: String? {
        switch self {
        case .volume: return nil
        case .directory(let delta): return delta.pathID
        }
    }

    /// Allocated growth in bytes, when the observation is a directory delta.
    public var allocatedGrowthBytes: Int64 {
        switch self {
        case .volume: return 0
        case .directory(let delta): return delta.growthBytes
        }
    }
}
