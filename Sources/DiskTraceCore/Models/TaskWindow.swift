import Foundation

/// Task lifecycle as observed from real event envelopes. A window with a known
/// start is bounded; `unknownStart` windows are placeholders and must not be
/// shown as a precise start or used to build a confident task window.
public enum TaskLifecycleState: String, Codable, Sendable, CaseIterable {
    case running
    case completed
    case aborted
    case interrupted
    case unknownStart
}

/// How far a client/schema has been verified. Only the acceptance program may
/// set `realClientVerified`; code never auto-promotes.
public enum VerificationState: String, Codable, Sendable {
    case unverified
    case fixtureOnly
    case realClientVerified
    case legacyUnverified
}

/// Companion context for an `AgentActivity`: the task window and its
/// verification provenance.
public struct TaskWindow: Sendable, Hashable, Codable {
    public let activityID: UUID
    public let sessionHash: String
    public let taskHash: String
    public let clientKind: AgentClientKind
    public let clientVersion: String?
    public let lifecycle: TaskLifecycleState
    public let startKnown: Bool
    public let endKnown: Bool
    public let lastEventAt: Date
    public let schemaKind: String
    public let verification: VerificationState
    public let sourceLogPath: String
    public let eventStartOffset: Int64?
    public let eventEndOffset: Int64?

    public init(
        activityID: UUID,
        sessionHash: String,
        taskHash: String,
        clientKind: AgentClientKind,
        clientVersion: String? = nil,
        lifecycle: TaskLifecycleState,
        startKnown: Bool,
        endKnown: Bool,
        lastEventAt: Date,
        schemaKind: String,
        verification: VerificationState,
        sourceLogPath: String,
        eventStartOffset: Int64? = nil,
        eventEndOffset: Int64? = nil
    ) {
        self.activityID = activityID
        self.sessionHash = sessionHash
        self.taskHash = taskHash
        self.clientKind = clientKind
        self.clientVersion = clientVersion
        self.lifecycle = lifecycle
        self.startKnown = startKnown
        self.endKnown = endKnown
        self.lastEventAt = lastEventAt
        self.schemaKind = schemaKind
        self.verification = verification
        self.sourceLogPath = sourceLogPath
        self.eventStartOffset = eventStartOffset
        self.eventEndOffset = eventEndOffset
    }

    /// A window may only act as a confident candidate when it is complete
    /// (bounded), verified for the client, and not stale.
    public func isConfidentCandidate(now: Date) -> Bool {
        guard verification == .realClientVerified else { return false }
        guard startKnown, endKnown, lifecycle == .completed else { return false }
        return now.timeIntervalSince(lastEventAt) <= 6 * 3600
    }
}

/// Recorded result of verifying a client/schema combination. Written only by the
/// acceptance tooling (or a fixture-labelled test), never by runtime startup.
public struct ClientVerification: Sendable, Hashable, Codable {
    public let clientKind: AgentClientKind
    public let clientVersion: String
    public let schemaKind: String
    public let result: VerificationState
    public let verifiedAt: Date?
    public let evidenceReference: String?

    public init(
        clientKind: AgentClientKind,
        clientVersion: String,
        schemaKind: String,
        result: VerificationState,
        verifiedAt: Date? = nil,
        evidenceReference: String? = nil
    ) {
        self.clientKind = clientKind
        self.clientVersion = clientVersion
        self.schemaKind = schemaKind
        self.result = result
        self.verifiedAt = verifiedAt
        self.evidenceReference = evidenceReference
    }
}
