import Foundation

/// Explicit attribution classes. Time overlap alone can never produce
/// `.agentConfirmed`; that requires a verified agent task event **and** a
/// process- or path-level operation for the changed path.
public enum EvidenceClass: String, Codable, Sendable, CaseIterable {
    case agentConfirmed
    case agentProbable
    case userConfirmed
    case userProbable
    case unknown
}

public enum EvidenceSource: String, Codable, Sendable {
    /// A user-configured or built-in path rule.
    case pathRule
    /// A verified, real process-level file operation observation.
    case processOperation
    /// A verified agent task/session event (e.g. a supported Codex signal).
    case agentTaskEvent
    /// Explicit user feedback or a user rule in scope.
    case userFeedback
    /// Directory name is suggestive only (e.g. `node_modules`); never proof.
    case directoryNameHint
    /// Cache directory hint (e.g. `~/.cache`); never proof.
    case cacheDirectoryHint
    /// A Finder / browser process hint with plausible time+directory context.
    case finderOrBrowserHint
}

public enum EvidenceScope: String, Codable, Sendable {
    case exactPath
    case subtree
    case timeWindowOnly
    case directoryName
}

public enum EvidenceStrength: Int, Codable, Sendable, Comparable {
    case weak = 0
    case moderate = 1
    case strong = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A single piece of attribution evidence. Evidence supplements observations
/// but never rewrites them. `identity` is a whitelisted identifier (hashed
/// session id, pid, client kind) — never prompt, command, source or file content.
public struct Evidence: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The observation this evidence supports.
    public let subjectID: UUID
    public let source: EvidenceSource
    public let scope: EvidenceScope
    public let strength: EvidenceStrength
    public let identity: String?
    public let observedAt: Date
    public let limitation: String

    public init(
        id: UUID = UUID(),
        subjectID: UUID,
        source: EvidenceSource,
        scope: EvidenceScope,
        strength: EvidenceStrength,
        identity: String? = nil,
        observedAt: Date,
        limitation: String
    ) {
        self.id = id
        self.subjectID = subjectID
        self.source = source
        self.scope = scope
        self.strength = strength
        self.identity = identity
        self.observedAt = observedAt
        self.limitation = limitation
    }

    /// True when this is a verified, real process-level file operation.
    public var isVerifiedProcessOperation: Bool {
        source == .processOperation && strength >= .moderate
    }

    /// True when this is a verified agent task/session event.
    public var isVerifiedAgentTaskEvent: Bool {
        source == .agentTaskEvent && strength >= .moderate
    }
}
