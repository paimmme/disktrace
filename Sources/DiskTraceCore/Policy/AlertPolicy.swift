import Foundation

public struct AlertPolicyConfig: Sendable {
    /// Minimum allocated growth for an agent-related directory delta to alert.
    public var agentGrowthThresholdBytes: Int64
    /// Absolute free-space floor below which a neutral safety alert fires.
    public var lowSpaceFreeBytes: Int64
    /// Fractional free-space floor (of capacity) for the same safety alert.
    public var lowSpaceFreeFraction: Double
    /// Minimum spacing between agent notifications for the same subject.
    public var cooldown: TimeInterval

    public init(
        agentGrowthThresholdBytes: Int64 = 1_000_000_000,
        lowSpaceFreeBytes: Int64 = 10_000_000_000,
        lowSpaceFreeFraction: Double = 0.05,
        cooldown: TimeInterval = 3_600
    ) {
        self.agentGrowthThresholdBytes = agentGrowthThresholdBytes
        self.lowSpaceFreeBytes = lowSpaceFreeBytes
        self.lowSpaceFreeFraction = lowSpaceFreeFraction
        self.cooldown = cooldown
    }
}

/// Pure decision function:
/// `AlertDecision = evaluate(StorageObservation, Evidence[], UserRules, PolicyVersion)`.
///
/// It decides **notification only** — it never deletes or rewrites observation
/// history, and it never lets time overlap alone become a confirmed agent alert.
public enum AlertPolicy {
    public static func evaluate(
        observation: StorageObservation,
        evidence: [Evidence],
        userRules: [UserRule],
        config: AlertPolicyConfig = AlertPolicyConfig(),
        now: Date,
        lastAlertAt: Date? = nil,
        policyVersion: String = AlertPolicyVersion.current
    ) -> AlertDecision {
        let relevant = evidence.filter { $0.subjectID == observation.subjectID }
        let path = observation.pathID
        let matchingRules = userRules.filter { rule in
            guard let path else { return false }
            return rule.matches(path: path, at: now)
        }
        let suppressingRule = matchingRules.first {
            $0.kind == .silenceSource || $0.kind == .confirmUser
        }
        let classification = classify(
            observation: observation,
            evidence: relevant,
            matchingRules: matchingRules,
            now: now
        )

        // Low-space safety is independent of cause and of classification.
        if case .volume(let sample) = observation {
            if isLowSpace(sample, config: config) {
                return AlertDecision(
                    ruleVersion: policyVersion,
                    subjectID: observation.subjectID,
                    action: .notifySafetyLowSpace,
                    reason: .lowSpaceSafety,
                    evidenceClass: .unknown,
                    evidenceIDs: [],
                    cooldownKey: "low-space:\(sample.volumeID)",
                    evaluatedAt: now
                )
            }
            return AlertDecision(
                ruleVersion: policyVersion,
                subjectID: observation.subjectID,
                action: .silent,
                reason: .unknownSource,
                evidenceClass: .unknown,
                evaluatedAt: now
            )
        }

        // Directory observations.
        if let suppressingRule {
            return AlertDecision(
                ruleVersion: policyVersion,
                subjectID: observation.subjectID,
                action: .silent,
                reason: suppressingRule.kind == .confirmUser ? .userExpectedActivity : .userRuleSuppressed,
                evidenceClass: .userConfirmed,
                evidenceIDs: relevant.map(\.id),
                evaluatedAt: now
            )
        }

        // Calibration uncertainty keeps us from alerting on an unreliable delta.
        if case .directory(let delta) = observation,
            delta.calibration == .coverageGap || delta.calibration == .pendingBaseline
        {
            return AlertDecision(
                ruleVersion: policyVersion,
                subjectID: observation.subjectID,
                action: .silent,
                reason: .calibrationUncertain,
                evidenceClass: classification,
                evidenceIDs: relevant.map(\.id),
                evaluatedAt: now
            )
        }

        let cooldownKey = path.map { "dir:\($0)" }
        switch classification {
        case .agentConfirmed, .agentProbable:
            let reason: AlertReason =
                classification == .agentConfirmed ? .agentConfirmedGrowth : .agentProbableGrowth
            let evidenceIDs = relevant.map(\.id)
            if observation.allocatedGrowthBytes < config.agentGrowthThresholdBytes {
                return AlertDecision(
                    ruleVersion: policyVersion, subjectID: observation.subjectID,
                    action: .silent, reason: .belowThreshold,
                    evidenceClass: classification, evidenceIDs: evidenceIDs,
                    cooldownKey: cooldownKey, evaluatedAt: now)
            }
            if let lastAlertAt, now.timeIntervalSince(lastAlertAt) < config.cooldown {
                return AlertDecision(
                    ruleVersion: policyVersion, subjectID: observation.subjectID,
                    action: .silent, reason: .cooldownActive,
                    evidenceClass: classification, evidenceIDs: evidenceIDs,
                    cooldownKey: cooldownKey, evaluatedAt: now)
            }
            return AlertDecision(
                ruleVersion: policyVersion, subjectID: observation.subjectID,
                action: .notifyAgentAnomaly, reason: reason,
                evidenceClass: classification, evidenceIDs: evidenceIDs,
                cooldownKey: cooldownKey, evaluatedAt: now)
        case .userConfirmed:
            return AlertDecision(
                ruleVersion: policyVersion, subjectID: observation.subjectID,
                action: .silent, reason: .userExpectedActivity,
                evidenceClass: .userConfirmed, evidenceIDs: relevant.map(\.id),
                evaluatedAt: now)
        case .userProbable:
            return AlertDecision(
                ruleVersion: policyVersion, subjectID: observation.subjectID,
                action: .silent, reason: .userExpectedActivity,
                evidenceClass: .userProbable, evidenceIDs: relevant.map(\.id),
                evaluatedAt: now)
        case .unknown:
            let reason: AlertReason = hasTimeOverlapOnly(relevant) ? .timeOverlapOnly : .unknownSource
            return AlertDecision(
                ruleVersion: policyVersion, subjectID: observation.subjectID,
                action: .silent, reason: reason,
                evidenceClass: .unknown, evidenceIDs: relevant.map(\.id),
                cooldownKey: cooldownKey, evaluatedAt: now)
        }
    }

    public static func classify(
        observation: StorageObservation,
        evidence: [Evidence],
        matchingRules: [UserRule] = [],
        now: Date
    ) -> EvidenceClass {
        if evidence.contains(where: { $0.source == .userFeedback }) { return .userConfirmed }
        if matchingRules.contains(where: { $0.kind == .confirmUser || $0.kind == .silenceSource }) {
            return .userConfirmed
        }
        let agentPathScoped = evidence.contains {
            $0.source == .agentTaskEvent && ($0.scope == .exactPath || $0.scope == .subtree)
        }
        let agentAny = evidence.contains { $0.source == .agentTaskEvent }
        let processOperation = evidence.contains { $0.isVerifiedProcessOperation }
        let finderBrowser = evidence.contains { $0.source == .finderOrBrowserHint }

        if processOperation && agentAny { return .agentConfirmed }
        if processOperation { return .agentProbable }
        if agentPathScoped { return .agentProbable }
        if finderBrowser { return .userProbable }
        return .unknown
    }

    private static func hasTimeOverlapOnly(_ evidence: [Evidence]) -> Bool {
        evidence.contains { $0.source == .agentTaskEvent && $0.scope == .timeWindowOnly }
    }

    private static func isLowSpace(_ sample: VolumeSample, config: AlertPolicyConfig) -> Bool {
        guard sample.status == .available, sample.capacityBytes > 0 else { return false }
        if sample.freeBytes < config.lowSpaceFreeBytes { return true }
        return sample.freeFraction < config.lowSpaceFreeFraction
    }
}
