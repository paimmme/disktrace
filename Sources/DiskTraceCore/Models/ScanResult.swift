import Foundation

public struct DirectorySize: Codable, Sendable, Hashable {
    /// Normalized absolute path.
    public let path: String
    public let allocatedBytes: Int64
    public let fileCount: Int

    public init(path: String, allocatedBytes: Int64, fileCount: Int) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
    }
}

/// The normalized result any scan backend must produce. Both the fixture
/// scanner and the (gated) Radix adapter converge on this type so directory
/// deltas are computed identically regardless of backend.
public struct ScanResult: Sendable, Hashable {
    public let root: String
    public let scannedAt: Date
    public let directories: [DirectorySize]
    public let totalAllocatedBytes: Int64
    public let totalFileCount: Int
    /// True when the scan could not fully traverse (permissions, overflow).
    public let incomplete: Bool
    public let checkpointID: UInt64

    public init(
        root: String,
        scannedAt: Date,
        directories: [DirectorySize],
        totalAllocatedBytes: Int64,
        totalFileCount: Int,
        incomplete: Bool,
        checkpointID: UInt64
    ) {
        self.root = root
        self.scannedAt = scannedAt
        self.directories = directories
        self.totalAllocatedBytes = totalAllocatedBytes
        self.totalFileCount = totalFileCount
        self.incomplete = incomplete
        self.checkpointID = checkpointID
    }

    public func allocatedBytes(forPath path: String) -> Int64? {
        directories.first { $0.path == path }?.allocatedBytes
    }

    /// Compute per-directory deltas between a previous scan and this one.
    public func deltas(from previous: ScanResult, windowStart: Date) -> [DirectoryDelta] {
        let beforeByPath = Dictionary(
            previous.directories.map { ($0.path, $0.allocatedBytes) },
            uniquingKeysWith: { first, _ in first })
        var result: [DirectoryDelta] = []
        for directory in directories {
            let before = beforeByPath[directory.path] ?? 0
            let delta = directory.allocatedBytes - before
            guard delta != 0 else { continue }
            result.append(
                DirectoryDelta(
                    pathID: directory.path,
                    windowStart: windowStart,
                    windowEnd: scannedAt,
                    deltaAllocatedBytes: delta,
                    beforeAllocatedBytes: before,
                    afterAllocatedBytes: directory.allocatedBytes,
                    checkpointID: checkpointID,
                    calibration: incomplete ? .coverageGap : .calibrated
                ))
        }
        return result
    }
}
