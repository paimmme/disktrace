import Foundation
import Testing

@testable import DiskTraceCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func delta(
    growth: Int64,
    path: String = "/Users/dev/project",
    calibration: CalibrationStatus = .calibrated
) -> DirectoryDelta {
    DirectoryDelta(
        pathID: path,
        windowStart: t0,
        windowEnd: t0.addingTimeInterval(600),
        deltaAllocatedBytes: growth,
        beforeAllocatedBytes: 0,
        afterAllocatedBytes: growth,
        checkpointID: 1,
        calibration: calibration)
}

private func evidence(
    _ delta: DirectoryDelta, source: EvidenceSource, scope: EvidenceScope,
    strength: EvidenceStrength = .moderate
) -> Evidence {
    Evidence(
        subjectID: delta.id, source: source, scope: scope, strength: strength,
        identity: "session", observedAt: delta.windowEnd, limitation: "test")
}

@Suite("Alert policy decision matrix")
struct AlertPolicyTests {
    @Test("confirmed agent growth notifies")
    func agentConfirmedNotifies() {
        let d = delta(growth: 5_000_000_000)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .processOperation, scope: .exactPath, strength: .strong),
                evidence(d, source: .agentTaskEvent, scope: .subtree),
            ],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .agentConfirmed)
        #expect(decision.action == .notifyAgentAnomaly)
        #expect(decision.reason == .agentConfirmedGrowth)
    }

    @Test("path-scoped agent task event is probable, not confirmed")
    func agentProbableNotifies() {
        let d = delta(growth: 5_000_000_000)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [evidence(d, source: .agentTaskEvent, scope: .subtree)],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .agentProbable)
        #expect(decision.action == .notifyAgentAnomaly)
    }

    @Test("time overlap only is never a confirmed agent alert")
    func timeOverlapOnlyIsUnknown() {
        let d = delta(growth: 5_000_000_000)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [evidence(d, source: .agentTaskEvent, scope: .timeWindowOnly, strength: .weak)],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .unknown)
        #expect(decision.action == .silent)
        #expect(decision.reason == .timeOverlapOnly)
    }

    @Test("node_modules hint alone stays unknown and silent")
    func directoryNameHintIsUnknown() {
        let d = delta(growth: 5_000_000_000, path: "/Users/dev/app/node_modules")
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .directoryNameHint, scope: .directoryName, strength: .weak)
            ],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .unknown)
        #expect(decision.action == .silent)
    }

    @Test("concurrent time overlap + cache hint + growth never accuses the agent")
    func concurrentEvidenceNeverAccuses() {
        let d = delta(growth: 50_000_000_000, path: "/Users/dev/Library/Caches/pkg")
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .agentTaskEvent, scope: .timeWindowOnly, strength: .weak),
                evidence(d, source: .cacheDirectoryHint, scope: .directoryName, strength: .weak),
            ],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .unknown)
        #expect(decision.action == .silent)
    }

    @Test("Finder/browser hint is user-probable and silent")
    func finderHintIsUserProbable() {
        let d = delta(growth: 3_000_000_000, path: "/Users/dev/Downloads")
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [evidence(d, source: .finderOrBrowserHint, scope: .subtree)],
            userRules: [],
            now: t0)
        #expect(decision.evidenceClass == .userProbable)
        #expect(decision.action == .silent)
        #expect(decision.reason == .userExpectedActivity)
    }

    @Test("explicit user rule suppresses agent alerts")
    func userRuleSuppresses() {
        let d = delta(growth: 9_000_000_000, path: "/Users/dev/Downloads")
        let rule = UserRule(
            kind: .silenceSource, pathPattern: "/Users/dev/Downloads/**",
            createdAt: t0.addingTimeInterval(-100), explanation: "my own downloads")
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .processOperation, scope: .exactPath, strength: .strong),
                evidence(d, source: .agentTaskEvent, scope: .subtree),
            ],
            userRules: [rule],
            now: t0)
        #expect(decision.action == .silent)
        #expect(decision.reason == .userRuleSuppressed)
        #expect(decision.evidenceClass == .userConfirmed)
    }

    @Test("growth below threshold is silent")
    func belowThreshold() {
        let d = delta(growth: 1_000)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .processOperation, scope: .exactPath, strength: .strong),
                evidence(d, source: .agentTaskEvent, scope: .subtree),
            ],
            userRules: [],
            now: t0)
        #expect(decision.action == .silent)
        #expect(decision.reason == .belowThreshold)
    }

    @Test("cooldown suppresses a repeat agent alert")
    func cooldownSuppresses() {
        let d = delta(growth: 9_000_000_000)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .processOperation, scope: .exactPath, strength: .strong),
                evidence(d, source: .agentTaskEvent, scope: .subtree),
            ],
            userRules: [],
            now: t0,
            lastAlertAt: t0.addingTimeInterval(-60))
        #expect(decision.action == .silent)
        #expect(decision.reason == .cooldownActive)
    }

    @Test("coverage-gap calibration suppresses alerts")
    func calibrationUncertainSuppresses() {
        let d = delta(growth: 9_000_000_000, calibration: .coverageGap)
        let decision = AlertPolicy.evaluate(
            observation: .directory(d),
            evidence: [
                evidence(d, source: .processOperation, scope: .exactPath, strength: .strong),
                evidence(d, source: .agentTaskEvent, scope: .subtree),
            ],
            userRules: [],
            now: t0)
        #expect(decision.action == .silent)
        #expect(decision.reason == .calibrationUncertain)
    }

    @Test("low space fires a neutral safety alert regardless of cause")
    func lowSpaceSafetyAlert() {
        let sample = VolumeSample(
            volumeID: "v1", observedAt: t0, freeBytes: 1_000_000_000,
            capacityBytes: 1_000_000_000_000, status: .available)
        let decision = AlertPolicy.evaluate(
            observation: .volume(sample), evidence: [], userRules: [], now: t0)
        #expect(decision.action == .notifySafetyLowSpace)
        #expect(decision.reason == .lowSpaceSafety)
        #expect(decision.evidenceClass == .unknown)
    }

    @Test("healthy volume is silent")
    func healthyVolumeSilent() {
        let sample = VolumeSample(
            volumeID: "v1", observedAt: t0, freeBytes: 500_000_000_000,
            capacityBytes: 1_000_000_000_000, status: .available)
        let decision = AlertPolicy.evaluate(
            observation: .volume(sample), evidence: [], userRules: [], now: t0)
        #expect(decision.action == .silent)
    }
}

@Suite("User rule matching")
struct UserRuleTests {
    @Test("subtree pattern matches descendants")
    func subtreeMatches() {
        let rule = UserRule(
            kind: .watch, pathPattern: "/Users/dev/Downloads", createdAt: t0,
            explanation: "x")
        #expect(rule.matches(path: "/Users/dev/Downloads", at: t0))
        #expect(rule.matches(path: "/Users/dev/Downloads/a/b", at: t0))
        #expect(!rule.matches(path: "/Users/dev/Other", at: t0))
    }

    @Test("glob star matches within a segment")
    func globMatches() {
        let rule = UserRule(
            kind: .watch, pathPattern: "/Users/*/secret", createdAt: t0, explanation: "x")
        #expect(rule.matches(path: "/Users/dev/secret", at: t0))
        #expect(!rule.matches(path: "/Users/dev/other", at: t0))
    }

    @Test("revoked and expired rules do not match")
    func revokedAndExpired() {
        var revoked = UserRule(
            kind: .silenceSource, pathPattern: "/x/**", createdAt: t0, explanation: "x")
        revoked.isRevoked = true
        #expect(!revoked.matches(path: "/x/y", at: t0))

        let expired = UserRule(
            kind: .silenceSource, pathPattern: "/y/**", createdAt: t0,
            expiresAt: t0.addingTimeInterval(-1), explanation: "y")
        #expect(!expired.matches(path: "/y/z", at: t0))
    }
}
