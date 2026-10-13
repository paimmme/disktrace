import Darwin
import Foundation

/// Typed probe failures. A reliable "does not exist" is separated from a
/// permission failure so a deletion is never inferred from a denied read.
public enum ProbeError: Error, Equatable, Sendable {
    case notFound
    case permissionDenied
    case other(code: Int32)

    public var isReliableAbsence: Bool { self == .notFound }
}

/// The single source of file metadata. Both the scanner and event-time path
/// probing call this, so allocation and identity semantics never diverge.
public struct MetadataProbe: Sendable {
    public init() {}

    /// Probes one path with `lstat` (never following symlinks).
    public func probe(_ path: String, observedAt: Date = Date()) -> Result<FileMetadata, ProbeError> {
        var fileStat = stat()
        if lstat(path, &fileStat) != 0 {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: return .failure(.notFound)
            case EACCES, EPERM: return .failure(.permissionDenied)
            default: return .failure(.other(code: code))
            }
        }
        return .success(makeMetadata(path: path, stat: fileStat, observedAt: observedAt))
    }

    /// Builds metadata from an already-obtained `stat` (used by the streaming
    /// traversal to avoid a second syscall per entry).
    public func makeMetadata(path: String, stat fileStat: stat, observedAt: Date) -> FileMetadata {
        let kind = kind(for: fileStat.st_mode)
        let birth = Date(timeIntervalSince1970: timeInterval(fileStat.st_birthtimespec))
        let modified = Date(timeIntervalSince1970: timeInterval(fileStat.st_mtimespec))
        let identity = "\(fileStat.st_dev):\(fileStat.st_ino):\(Int64(birth.timeIntervalSince1970))"
        return FileMetadata(
            path: path,
            fileIdentity: identity,
            kind: kind,
            logicalBytes: kind == .regularFile ? Int64(fileStat.st_size) : nil,
            allocatedBytes: kind == .regularFile ? allocatedBytes(path: path, stat: fileStat) : nil,
            modifiedAt: modified,
            birthAt: birth,
            observedAt: observedAt,
            linkCount: Int(fileStat.st_nlink))
    }

    private func kind(for mode: mode_t) -> FileKind {
        switch mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// Allocated bytes from the URL API when present, else `st_blocks * 512`.
    /// Returns `nil` only when neither is available (never coerced to 0).
    private func allocatedBytes(path: String, stat fileStat: stat) -> Int64? {
        if let values = try? URL(filePath: path).resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
            let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        {
            return Int64(allocated)
        }
        let fromBlocks = Int64(fileStat.st_blocks) * 512
        return fromBlocks > 0 ? fromBlocks : nil
    }

    private func timeInterval(_ ts: timespec) -> TimeInterval {
        TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}
