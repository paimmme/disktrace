import Foundation

public enum FileKind: String, Codable, Sendable {
    case regularFile
    case directory
    case symlink
    case other
}

/// A single file's metadata, captured by one probe so scans and event-time
/// stats never diverge. No file content is read; `allocatedBytes`/`logicalBytes`
/// are `nil` when the platform does not provide them (never coerced to 0).
public struct FileMetadata: Sendable, Hashable {
    public let path: String
    /// `device:inode[:birth]` — stable across a rename, not just an inode.
    public let fileIdentity: String
    public let kind: FileKind
    public let logicalBytes: Int64?
    public let allocatedBytes: Int64?
    public let modifiedAt: Date?
    public let birthAt: Date?
    public let observedAt: Date
    public let linkCount: Int

    public init(
        path: String,
        fileIdentity: String,
        kind: FileKind,
        logicalBytes: Int64?,
        allocatedBytes: Int64?,
        modifiedAt: Date?,
        birthAt: Date?,
        observedAt: Date,
        linkCount: Int
    ) {
        self.path = path
        self.fileIdentity = fileIdentity
        self.kind = kind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.modifiedAt = modifiedAt
        self.birthAt = birthAt
        self.observedAt = observedAt
        self.linkCount = linkCount
    }
}

/// One emitted item from a streaming scan.
public enum ScanEntry: Sendable {
    case file(FileMetadata)
    case directory(DirectorySize)
    case inaccessible(path: String, code: Int32)
}

public enum ScanTermination: String, Sendable {
    case completed
    case depthLimited
    case entryLimited
    case timeLimited
    case cancelled
    case storageError
}

public struct ScanLimits: Sendable {
    public var maxDepth: Int
    public var maxEntries: Int
    public var maxDuration: TimeInterval
    public var maxDirectories: Int
    /// Per-batch producer/consumer buffer bound (entries staged before a commit).
    public var batchSize: Int

    public init(
        maxDepth: Int = 64, maxEntries: Int = 200_000, maxDuration: TimeInterval = 120,
        maxDirectories: Int = 20_000, batchSize: Int = 256
    ) {
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
        self.maxDuration = maxDuration
        self.maxDirectories = maxDirectories
        self.batchSize = batchSize
    }

    public static let `default` = ScanLimits()
}

public struct ScanCompletion: Sendable {
    public let root: String
    public let startedAt: Date
    public let endedAt: Date
    public let complete: Bool
    public let entryCount: Int
    public let directoryCount: Int
    public let checkpointID: UInt64
    public let termination: ScanTermination
    /// False when at least one regular file's allocated size could not be read,
    /// so directory totals are a lower bound rather than an exact figure.
    public let sizeComplete: Bool

    public init(
        root: String, startedAt: Date, endedAt: Date, complete: Bool, entryCount: Int,
        directoryCount: Int, checkpointID: UInt64, termination: ScanTermination,
        sizeComplete: Bool = true
    ) {
        self.root = root
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.complete = complete
        self.entryCount = entryCount
        self.directoryCount = directoryCount
        self.checkpointID = checkpointID
        self.termination = termination
        self.sizeComplete = sizeComplete
    }
}
