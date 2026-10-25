import CryptoKit
import Foundation

public enum AgentClientKind: String, Codable, Sendable {
    case codexCLI
    case codexIDE
    case codexDesktop
    case claudeCode
    case cursorAgent
    case unknown
}

/// Minimal, non-content agent session metadata. Holds only whitelisted fields:
/// a hashed session identifier, a task/turn identity, a time window, an optional
/// working directory and a client kind. Never prompt, command, message or file
/// content.
public struct AgentActivity: Codable, Sendable, Hashable, Identifiable {
    /// Deterministic id: re-reading the same session/task upserts one row instead
    /// of appending duplicates.
    public let id: UUID
    public let sessionIDHash: String
    public let client: AgentClientKind
    public let startedAt: Date
    public let endedAt: Date?
    /// Normalized working directory, or a hash when privacy mode is on.
    public let workingDirectory: String?
    /// Hashed task/turn identity when the log exposes one; nil for a session-level
    /// activity.
    public let taskIDHash: String?
    /// True only when the window came from explicit task start *and* end events.
    /// An open-ended window (idle time may be included) is lower confidence.
    public let windowIsTaskBounded: Bool

    public init(
        id: UUID? = nil,
        sessionIDHash: String,
        client: AgentClientKind,
        startedAt: Date,
        endedAt: Date? = nil,
        workingDirectory: String? = nil,
        taskIDHash: String? = nil,
        windowIsTaskBounded: Bool = false
    ) {
        self.id = id ?? Self.stableID(sessionIDHash: sessionIDHash, taskIDHash: taskIDHash)
        self.sessionIDHash = sessionIDHash
        self.client = client
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.workingDirectory = workingDirectory
        self.taskIDHash = taskIDHash
        self.windowIsTaskBounded = windowIsTaskBounded
    }

    /// Deterministic UUID derived from the session and task identity.
    public static func stableID(sessionIDHash: String, taskIDHash: String?) -> UUID {
        let key = sessionIDHash + "|" + (taskIDHash ?? "session")
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]
            ))
    }

    public func overlaps(start: Date, end: Date) -> Bool {
        let activityEnd = endedAt ?? startedAt
        return startedAt <= end && activityEnd >= start
    }
}
