import Foundation
import Testing

@testable import DiskTraceCore

@Suite("Interval explanation report")
struct IntervalReportTests {
    @Test("separates Codex update cache from session paths")
    func purposeSplit() {
        let changes = [
            fakeChange(path: "/Users/x/Library/Caches/com.openai.codex/big.bin", delta: 1_000_000),
            fakeChange(path: "/Users/x/.codex/sessions/log.jsonl", delta: 500_000),
        ]
        let report = IntervalReportBuilder.build(
            samples: [], sampleMethods: [:], swapSamples: [], fileChanges: changes,
            gaps: [], from: Date(), to: Date(), buildGitCommit: nil, buildSchema: 7)
        let purposes = Set(report.purposeGroups.map(\.purpose))
        #expect(purposes.contains(.codexAutoUpdate))
        #expect(purposes.contains(.codexSessionData))
    }

    @Test("method mismatch blocks volume delta")
    func methodGuard() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 60)
        let s1 = VolumeSample(volumeID: "v", observedAt: t0, freeBytes: 100, capacityBytes: 1_000, status: .available)
        let s2 = VolumeSample(volumeID: "v", observedAt: t1, freeBytes: 80, capacityBytes: 1_000, status: .available)
        let report = IntervalReportBuilder.build(
            samples: [s1, s2],
            sampleMethods: [s1.id: .statfsAvailable, s2.id: .importantUsage],
            swapSamples: [], fileChanges: [], gaps: [], from: t0, to: t1,
            buildGitCommit: "abc", buildSchema: 7)
        #expect(report.volume.freeDelta == nil)
        #expect(!report.volume.methodComparable)
    }
}

private func fakeChange(path: String, delta: Int64) -> FileChange {
    FileChange(
        id: UUID(), rootID: UUID(), scanID: nil, pathBefore: path, pathAfter: path,
        identityBefore: "a", identityAfter: "a", kind: .grown, windowStart: Date(),
        windowEnd: Date(), observedAt: Date(), beforeLogical: nil, afterLogical: nil,
        beforeAllocated: 0, afterAllocated: delta, deltaAllocated: delta,
        measurement: .measured, timing: .liveHintWindow, evidenceVersion: 1)
}
