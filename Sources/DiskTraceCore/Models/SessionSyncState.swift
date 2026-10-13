import Foundation

/// Durable per-session-log cursor.
///
/// `byteOffset` is the **committed** offset: the end of the last complete line
/// that was successfully processed and committed together with task state. It
/// is never a mid-line `readPosition`. `fileSize` is only the size observed when
/// the cursor was written — it is not proof that the file was read to EOF.
public struct SessionSyncState: Codable, Sendable, Hashable {
    public let filePath: String
    /// `device:inode` — detects replacement/rotation independent of the path.
    public let fileIdentity: String
    public let sessionIDHash: String?
    public let byteOffset: Int64
    public let fileSize: Int64
    public let modifiedAt: Date?
    public let lastProcessed: Date
    public let workingDirectory: String?
    /// 1 when `byteOffset` is known to be a complete-line boundary; 0 for a
    /// legacy cursor written before v4 (needs a one-time repair).
    public let cursorVersion: Int
    /// True while skipping an oversized record that has not yet hit a newline.
    public let discardingOversized: Bool
    public let firstEventAt: Date?
    public let lastEventAt: Date?
    public let lastError: String?
    public let retryAfter: Date?
    public let lastScheduledAt: Date?

    public init(
        filePath: String,
        fileIdentity: String,
        sessionIDHash: String?,
        byteOffset: Int64,
        fileSize: Int64,
        modifiedAt: Date?,
        lastProcessed: Date,
        workingDirectory: String? = nil,
        cursorVersion: Int = 1,
        discardingOversized: Bool = false,
        firstEventAt: Date? = nil,
        lastEventAt: Date? = nil,
        lastError: String? = nil,
        retryAfter: Date? = nil,
        lastScheduledAt: Date? = nil
    ) {
        self.filePath = filePath
        self.fileIdentity = fileIdentity
        self.sessionIDHash = sessionIDHash
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.lastProcessed = lastProcessed
        self.workingDirectory = workingDirectory
        self.cursorVersion = cursorVersion
        self.discardingOversized = discardingOversized
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.lastError = lastError
        self.retryAfter = retryAfter
        self.lastScheduledAt = lastScheduledAt
    }
}
