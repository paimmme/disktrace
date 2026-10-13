import Foundation

public enum AlertAction: String, Codable, Sendable {
    /// A reasoned AI-agent anomaly notification.
    case notifyAgentAnomaly
    /// A neutral, cause-agnostic low-space safety notification.
    case notifySafetyLowSpace
    /// Recorded but not surfaced.
    case silent
}

public enum AlertReason: String, Codable, Sendable {
    case agentConfirmedGrowth
    case agentProbableGrowth
    case timeOverlapOnly
    case userExpectedActivity
    case userRuleSuppressed
    case belowThreshold
    case cooldownActive
    case unknownSource
    case lowSpaceSafety
    case calibrationUncertain
}

/// The outcome of evaluating one observation against evidence and user rules.
/// Kept separate from observations and evidence; a decision never mutates them.
public struct AlertDecision: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let ruleVersion: String
    public let subjectID: UUID
    public let action: AlertAction
    public let reason: AlertReason
    public let evidenceClass: EvidenceClass
    public let evidenceIDs: [UUID]
    public let cooldownKey: String?
    public let evaluatedAt: Date

    public init(
        id: UUID = UUID(),
        ruleVersion: String,
        subjectID: UUID,
        action: AlertAction,
        reason: AlertReason,
        evidenceClass: EvidenceClass,
        evidenceIDs: [UUID] = [],
        cooldownKey: String? = nil,
        evaluatedAt: Date
    ) {
        self.id = id
        self.ruleVersion = ruleVersion
        self.subjectID = subjectID
        self.action = action
        self.reason = reason
        self.evidenceClass = evidenceClass
        self.evidenceIDs = evidenceIDs
        self.cooldownKey = cooldownKey
        self.evaluatedAt = evaluatedAt
    }

    public var notifies: Bool { action != .silent }
}
