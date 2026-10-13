import Foundation

public enum AgentClientKind: String, Codable, Sendable {
    case codexCLI
    case codexIDE
    case codexDesktop
    case claudeCode
    case unknown
}

/// Minimal, non-content agent session metadata. Holds only whitelisted fields:
/// a hashed session identifier, a time window, an optional working directory and
/// a client kind. Never prompt, command, message or file content.
public struct AgentActivity: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sessionIDHash: String
    public let client: AgentClientKind
    public let startedAt: Date
    public let endedAt: Date?
    /// Normalized working directory, or a hash when privacy mode is on.
    public let workingDirectory: String?

    public init(
        id: UUID = UUID(),
        sessionIDHash: String,
        client: AgentClientKind,
        startedAt: Date,
        endedAt: Date? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.sessionIDHash = sessionIDHash
        self.client = client
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.workingDirectory = workingDirectory
    }

    public func overlaps(start: Date, end: Date) -> Bool {
        let activityEnd = endedAt ?? startedAt
        return startedAt <= end && activityEnd >= start
    }
}
