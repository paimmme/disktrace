import Foundation

/// Versioned, local-only request/response contract between the App and the
/// Agent. Recomputed as Codable so it can travel over XPC or a read-only
/// shared snapshot without introducing an HTTP/WebSocket surface (ADR-03/08).
public enum IPCProtocolVersion {
    public static let current = 1
}

public struct IPCRequest: Codable, Sendable {
    public let version: Int
    public let command: Command

    public init(version: Int = IPCProtocolVersion.current, command: Command) {
        self.version = version
        self.command = command
    }

    public enum Command: Codable, Sendable {
        case health
        case timeline(from: Date, to: Date)
        case topGrowth(from: Date, to: Date, limit: Int)
        case recentAlerts(limit: Int)
        case pauseMonitoring
        case resumeMonitoring
        case addRule(kind: UserRuleKind, pattern: String, explanation: String)
        case revokeRule(id: UUID)
    }
}

public struct IPCResponse: Codable, Sendable {
    public let version: Int
    public let payload: Payload
    public let error: String?

    public init(version: Int = IPCProtocolVersion.current, payload: Payload, error: String? = nil) {
        self.version = version
        self.payload = payload
        self.error = error
    }

    public enum Payload: Codable, Sendable {
        case health(MonitorHealth)
        case timeline([VolumeSample])
        case growth([DirectoryDelta])
        case alerts([AlertDecision])
        case acknowledged(Bool)
    }
}
