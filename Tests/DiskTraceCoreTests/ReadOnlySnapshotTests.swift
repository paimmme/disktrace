import Foundation
import Testing
@testable import DiskTraceCore

@Suite("UI read-only snapshots")
struct ReadOnlySnapshotTests {
    @Test("reader queries history but cannot modify or create databases")
    func readOnlyDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.sqlite").path
        let writer = try DiskTraceStore(path: path)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = VolumeSample(volumeID: "v", observedAt: now, freeBytes: 10, capacityBytes: 100, status: .available)
        try await writer.insert(sample)
        let reader = try DiskTraceStore(path: path, readOnly: true)
        let samples = try await reader.timelineSamples(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        #expect(samples.count == 1)
        do {
            try await reader.insert(VolumeSample(volumeID: "v", observedAt: now, freeBytes: 5, capacityBytes: 100, status: .available))
            Issue.record("Read-only UI connection accepted a write")
        } catch let error as SQLiteError {
            #expect(error.code == 8)
        }
        let missing = root.appendingPathComponent("missing.sqlite").path
        #expect(throws: SQLiteError.self) { _ = try DiskTraceStore(path: missing, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test("silent decisions and evidence remain available to the detail interface")
    func inspectSilentReason() async throws {
        let store = try DiskTraceStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let subject = UUID()
        let evidence = Evidence(subjectID: subject, source: .agentTaskEvent, scope: .timeWindowOnly, strength: .weak,
                                observedAt: now, limitation: "Time overlap only")
        try await store.insert(evidence)
        try await store.insert(AlertDecision(ruleVersion: "1", subjectID: subject, action: .silent, reason: .timeOverlapOnly,
                                             evidenceClass: .unknown, evidenceIDs: [evidence.id], evaluatedAt: now))
        let all = try await store.decisions(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        let alerts = try await store.notifyingDecisions(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        let loaded = try await store.evidence(subjectID: subject)
        #expect(all.count == 1)
        #expect(alerts.isEmpty)
        #expect(loaded == [evidence])
        #expect(try await store.evidence(subjectID: UUID()).isEmpty)
    }
}
