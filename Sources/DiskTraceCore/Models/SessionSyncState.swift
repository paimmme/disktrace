import Foundation

public struct SessionSyncState: Codable, Sendable, Hashable {
    public let filePath: String
    /// `device:inode` — detects replacement/rotation independent of the path.
    public let fileIdentity: String
    public let sessionIDHash: String?
    /// Byte offset of the last complete line consumed.
    public let byteOffset: Int64
    public let fileSize: Int64
    public let modifiedAt: Date?
    public let lastProcessed: Date
    /// Persisted so session working-directory survives a restart.
    public let workingDirectory: String?

    public init(
        filePath: String,
        fileIdentity: String,
        sessionIDHash: String?,
        byteOffset: Int64,
        fileSize: Int64,
        modifiedAt: Date?,
        lastProcessed: Date,
        workingDirectory: String? = nil
    ) {
        self.filePath = filePath
        self.fileIdentity = fileIdentity
        self.sessionIDHash = sessionIDHash
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.lastProcessed = lastProcessed
        self.workingDirectory = workingDirectory
    }
}
