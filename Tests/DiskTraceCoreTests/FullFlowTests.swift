import Foundation
import Testing

@testable import DiskTraceCore

private func makeTemp(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-flow-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

@discardableResult
private func writeBytes(_ url: URL, _ count: Int) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: count).write(to: url)
    return url
}

/// The end-to-end acceptance the review asks for: start the agent, append a
/// session log, write directory growth, run a calibration cycle, and confirm the
/// database holds the matching activity, delta and decision.
@Suite("Full flow")
struct FullFlowTests {
    @Test("start → append session + write dirs → cycle records activity, delta and decision")
    func fullFlow() async throws {
        let root = try makeTemp("root")
        let home = try makeTemp("codexhome")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let rootPath = FilePaths.canonical(root.path)

        let sessionsDir = home.appending(path: "sessions/2026/10/13", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let log = sessionsDir.appending(path: "rollout.jsonl")
        let now = Date()
        let opening = [
            #"{"type":"session_meta","timestamp":"\#(isoString(now))","payload":{"session_id":"sess-e2e","cwd":"\#(rootPath)"}}"#,
            #"{"type":"task_started","timestamp":"\#(isoString(now))","payload":{"task_id":"t1"}}"#,
        ]
        try Data((opening.joined(separator: "\n") + "\n").utf8).write(to: log)

        let store = try DiskTraceStore(path: try makeTemp("db").appending(path: "db.sqlite").path)
        var policy = AlertPolicyConfig()
        policy.agentGrowthThresholdBytes = 1_000
        policy.lowSpaceFreeBytes = 0
        policy.lowSpaceFreeFraction = 0
        let sync = AgentActivitySync(
            configuration: CodexIntegrationConfiguration(codexHome: home))
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(
                roots: [root], sampleInterval: 100_000, calibrationInterval: 0, policy: policy),
            store: store, scanner: FixtureScanner(), scannerName: "fixture",
            activitySync: sync)

        try await coordinator.start()  // baseline scan + first sync (open task)

        // Directory growth, then close the task in the appended log.
        try writeBytes(root.appending(path: "node_modules/dep/big.bin"), 300_000)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                (#"{"type":"task_completed","timestamp":"\#(isoString(now.addingTimeInterval(5)))","payload":{"task_id":"t1"}}"# + "\n")
                    .utf8))
        try? handle.close()

        let report = try await coordinator.runOnce()

        // Delta recorded for the root subtree.
        #expect(report.deltas.contains { $0.pathID == rootPath })

        // Activity present and bounded (explicit start + end).
        let activities = try await store.activities(
            from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400))
        #expect(activities.contains { $0.windowIsTaskBounded && $0.workingDirectory == rootPath })

        // Decision: agent-probable anomaly notification.
        #expect(
            report.decisions.contains {
                $0.action == .notifyAgentAnomaly && $0.evidenceClass == .agentProbable
            })

        let counts = try await store.rowCounts()
        #expect((counts["agent_activities"] ?? 0) >= 1)
        #expect((counts["directory_changes"] ?? 0) >= 1)
        #expect((counts["session_sync"] ?? 0) >= 1)
    }
}
