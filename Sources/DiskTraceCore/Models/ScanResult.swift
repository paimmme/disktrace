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

    /// Compute per-directory deltas between a previous scan and this one, over
    /// the **union** of before/after paths so removed directories are recorded
    /// as negative change instead of silently disappearing.
    ///
    /// Returns `[]` (no trusted delta) whenever either scan is incomplete — a
    /// permission loss must never masquerade as a deletion and a permission
    /// recovery must never masquerade as growth. The coordinator records a
    /// `CoverageGap` and re-baselines when the scan becomes complete again.
    ///
    /// A rename is expressed as an old-path decrease plus a new-path increase;
    /// with no file-identity evidence, no move relationship is inferred.
    public func deltas(from previous: ScanResult, windowStart: Date) -> [DirectoryDelta] {
        guard !previous.incomplete, !incomplete else { return [] }
        let before = Self.allocatedMap(previous.directories)
        let after = Self.allocatedMap(directories)
        let paths = Set(before.keys).union(after.keys)
        var result: [DirectoryDelta] = []
        for path in paths {
            let oldBytes = before[path] ?? 0
            let newBytes = after[path] ?? 0
            let delta = newBytes - oldBytes
            guard delta != 0 else { continue }
            result.append(
                DirectoryDelta(
                    pathID: path,
                    windowStart: windowStart,
                    windowEnd: scannedAt,
                    deltaAllocatedBytes: delta,
                    beforeAllocatedBytes: oldBytes,
                    afterAllocatedBytes: newBytes,
                    checkpointID: checkpointID,
                    calibration: .calibrated))
        }
        return result.sorted { abs($0.deltaAllocatedBytes) > abs($1.deltaAllocatedBytes) }
    }

    /// Drops any delta whose ancestor directory is also present, so parent and
    /// child subtree totals are never summed into one misleading number.
    public static func nonOverlapping(_ deltas: [DirectoryDelta]) -> [DirectoryDelta] {
        let paths = Set(deltas.map(\.pathID))
        return deltas.filter { delta in
            var ancestor = delta.pathID
            while let index = ancestor.lastIndex(of: "/"), index != ancestor.startIndex {
                ancestor = String(ancestor[..<index])
                if paths.contains(ancestor) { return false }
            }
            return !paths.contains("/")
        }
    }

    private static func allocatedMap(_ directories: [DirectorySize]) -> [String: Int64] {
        Dictionary(
            directories.map { ($0.path, $0.allocatedBytes) },
            uniquingKeysWith: { first, _ in first })
    }
}
