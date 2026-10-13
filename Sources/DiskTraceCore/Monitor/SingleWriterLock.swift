import Darwin
import Foundation

public enum SingleWriterLockError: Error, Sendable {
    case openFailed(Int32)
    case alreadyHeld
}

/// A POSIX `flock`-based single-writer lease. The second agent on the same
/// database fails to acquire it and must exit without opening a write connection.
public final class SingleWriterLock: @unchecked Sendable {
    private var descriptor: Int32 = -1

    public init(path: String) throws {
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SingleWriterLockError.openFailed(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw SingleWriterLockError.alreadyHeld
        }
        descriptor = fd
        _ = ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    deinit { release() }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
