import Foundation
import Testing

@testable import DiskTraceCore

private func tempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-test-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SQLite store")
struct StoreTests {
    @Test("migration is idempotent and reopens cleanly")
    func migrationIdempotent() async throws {
        let directory = try tempDirectory("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "db.sqlite").path

        let store = try DiskTraceStore(path: path)
        try await store.insert(
            VolumeSample(
                volumeID: "v", observedAt: Date(), freeBytes: 10, capacityBytes: 100,
                status: .available))
        // Re-open: migrate must not throw or duplicate schema.
        let reopened = try DiskTraceStore(path: path)
        let counts = try await reopened.rowCounts()
        #expect(counts["volume_samples"] == 1)
    }

    @Test("volume samples round-trip and query by range")
    func volumeSamplesRoundTrip() async throws {
        let store = try DiskTraceStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for offset in 0..<5 {
            try await store.insert(
                VolumeSample(
                    volumeID: "v1", observedAt: base.addingTimeInterval(Double(offset)),
                    freeBytes: Int64(offset), capacityBytes: 100, status: .available))
        }
        let latest = try await store.latestVolumeSample(volumeID: "v1")
        #expect(latest?.freeBytes == 4)
        let range = try await store.volumeSamples(
            volumeID: "v1", from: base, to: base.addingTimeInterval(2))
        #expect(range.count == 3)
    }

    @Test("directory deltas honor the minimum-growth filter")
    func deltaFilter() async throws {
        let store = try DiskTraceStore.inMemory()
        let now = Date()
        for growth in [Int64(100), 5_000, 10_000] {
            try await store.insert(
                DirectoryDelta(
                    pathID: "/p/\(growth)", windowStart: now, windowEnd: now,
                    deltaAllocatedBytes: growth, beforeAllocatedBytes: 0,
                    afterAllocatedBytes: growth, checkpointID: 1, calibration: .calibrated))
        }
        let big = try await store.directoryDeltas(
            from: now.addingTimeInterval(-10), to: now.addingTimeInterval(10), minimumGrowth: 1_000)
        #expect(big.count == 2)
    }

    @Test("only notifying decisions are returned")
    func notifyingDecisions() async throws {
        let store = try DiskTraceStore.inMemory()
        let now = Date()
        try await store.insert(
            AlertDecision(
                ruleVersion: "1", subjectID: UUID(), action: .notifyAgentAnomaly,
                reason: .agentProbableGrowth, evidenceClass: .agentProbable, evaluatedAt: now))
        try await store.insert(
            AlertDecision(
                ruleVersion: "1", subjectID: UUID(), action: .silent,
                reason: .unknownSource, evidenceClass: .unknown, evaluatedAt: now))
        let alerts = try await store.notifyingDecisions(
            from: now.addingTimeInterval(-10), to: now.addingTimeInterval(10))
        #expect(alerts.count == 1)
        #expect(alerts.first?.action == .notifyAgentAnomaly)
    }

    @Test("user rules persist and revoke")
    func userRules() async throws {
        let store = try DiskTraceStore.inMemory()
        let rule = UserRule(
            kind: .silenceSource, pathPattern: "/Users/dev/Downloads/**",
            createdAt: Date(), explanation: "mine")
        try await store.save(rule)
        var rules = try await store.userRules()
        #expect(rules.count == 1)
        #expect(rules.first?.isRevoked == false)
        try await store.revokeRule(id: rule.id)
        rules = try await store.userRules()
        #expect(rules.first?.isRevoked == true)
    }

    @Test("monitor state and last alert lookup")
    func monitorState() async throws {
        let store = try DiskTraceStore.inMemory()
        try await store.setState("checkpoint", "42", at: Date())
        #expect(try await store.state("checkpoint") == "42")

        let now = Date()
        try await store.insert(
            AlertDecision(
                ruleVersion: "1", subjectID: UUID(), action: .notifyAgentAnomaly,
                reason: .agentConfirmedGrowth, evidenceClass: .agentConfirmed,
                cooldownKey: "dir:/x", evaluatedAt: now))
        let returned = try await store.lastAlertDate(cooldownKey: "dir:/x")
        #expect(returned != nil)
        #expect(abs((returned ?? .distantPast).timeIntervalSince(now)) < 0.001)
        #expect(try await store.lastAlertDate(cooldownKey: "dir:/y") == nil)
    }
}

@Suite("Retention")
struct RetentionTests {
    @Test("prunes stale evidence/decisions/activities and downsamples old samples")
    func pruneHistory() async throws {
        let store = try DiskTraceStore.inMemory()
        let now = Date()
        for hour in 0..<(30 * 24) {
            try await store.insert(
                VolumeSample(
                    id: UUID(),
                    volumeID: "v1",
                    observedAt: now.addingTimeInterval(-Double(hour) * 3_600),
                    freeBytes: 1_000, capacityBytes: 1_000_000, status: .available))
        }
        try await store.insert(
            Evidence(
                subjectID: UUID(), source: .pathRule, scope: .exactPath, strength: .weak,
                observedAt: now.addingTimeInterval(-30 * 86_400), limitation: "old"))
        try await store.insert(
            AlertDecision(
                ruleVersion: "1", subjectID: UUID(), action: .silent, reason: .unknownSource,
                evidenceClass: .unknown, evaluatedAt: now.addingTimeInterval(-30 * 86_400)))

        let before = try await store.rowCounts()
        let report = try await store.pruneHistory(
            RetentionPolicy(
                samplesDetailedDays: 1, samplesHourlyDays: 7, evidenceDays: 7,
                decisionsDays: 7),
            now: now)
        let after = try await store.rowCounts()

        #expect(report.evidenceDeleted == 1)
        #expect(report.decisionsDeleted == 1)
        #expect(report.samplesDownsampled > 0)
        #expect(after["volume_samples"]! < before["volume_samples"]!)
        #expect(after["evidence"] == 0)
    }

    @Test("open coverage gaps and user rules are protected")
    func protectsOpenGapsAndRules() async throws {
        let store = try DiskTraceStore.inMemory()
        let now = Date()
        try await store.insert(
            CoverageGap(
                start: now.addingTimeInterval(-200 * 86_400), end: nil,
                cause: .manualPause, affectedRoots: ["/r"], severity: .low))
        try await store.insert(
            CoverageGap(
                start: now.addingTimeInterval(-200 * 86_400),
                end: now.addingTimeInterval(-200 * 86_400 + 60),
                cause: .agentRestart, affectedRoots: ["/r"], severity: .low))
        try await store.save(
            UserRule(
                kind: .watch, pathPattern: "/old/**",
                createdAt: now.addingTimeInterval(-400 * 86_400), explanation: "keep me"))

        _ = try await store.pruneHistory(RetentionPolicy(gapsDays: 1), now: now)
        let counts = try await store.rowCounts()
        #expect(counts["coverage_gaps"] == 1)  // the closed gap was pruned, the open one kept
        #expect(counts["user_rules"] == 1)
    }

    @Test("quota enforcement prunes rows and reports reclaimable space")
    func quotaPrunes() async throws {
        let directory = try tempDirectory("quota")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DiskTraceStore(path: directory.appending(path: "db.sqlite").path)
        let now = Date()
        for index in 0..<5_000 {
            try await store.insert(
                VolumeSample(
                    volumeID: "v1", observedAt: now.addingTimeInterval(Double(index)),
                    freeBytes: Int64(index), capacityBytes: 1_000_000, status: .available))
        }
        let big = await store.spaceReport()
        #expect(big.effectiveBytes > 0)

        let report = try await store.applyRetention(
            RetentionPolicy(softQuotaBytes: 1), now: now.addingTimeInterval(400 * 86_400))
        #expect(report.rowsDeletedForQuota > 0)
        #expect(report.space.effectiveBytes <= big.effectiveBytes)
    }
}
