import Foundation
import Testing

@testable import DiskTraceCore

private let normalFree: Int64 = 500_000_000_000  // ~500 GB
private let constrainedFree: Int64 = 1_500_000_000  // ~1.5 GB
private let criticalFree: Int64 = 500_000_000  // ~0.5 GB

private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-lsre-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 4096).write(to: url.appending(path: "seed.bin"))
    return url
}

@Suite("Low space & restart (LS/RE series)")
struct ResourceAndRestartTests {
    @Test("LS01/LS02: low space keeps volume + safety alert but suspends inventory")
    func constrainedState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiskTraceStore.inMemory()
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0),
            store: store, scanner: FixtureScanner(),
            sampler: VolumeSampler(fixedFree: constrainedFree), scannerName: "fixture")
        try await coordinator.start()
        _ = try await coordinator.runOnce()

        let counts = try await store.rowCounts()
        #expect(counts["volume_samples"] ?? 0 >= 1)
        let decisions = try await store.decisions(
            from: Date().addingTimeInterval(-600), to: Date().addingTimeInterval(600))
        #expect(decisions.contains { $0.action == .notifySafetyLowSpace })
        // No agent-anomaly alert because no scan happened.
        #expect(!decisions.contains { $0.action == .notifyAgentAnomaly })

        let health = try await store.rootHealth(
            rootID: MonitoredRoot.stableID(canonicalPath: FilePaths.canonical(root.path)))
        #expect(health?.state == .quotaLimited)

        // A constrained run must not grow the file-change table.
        let before = th(try await store.rowCounts())["file_changes"] ?? 0
        _ = try await coordinator.runOnce()
        let after = th(try await store.rowCounts())["file_changes"] ?? 0
        #expect(before == after)
    }

    @Test("RE01: restart with no changes produces no spurious facts")
    func restartQuiet() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-re01-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path

        let store1 = try DiskTraceStore(path: path)
        let c1 = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0), store: store1,
            scanner: FixtureScanner(), sampler: VolumeSampler(fixedFree: normalFree),
            scannerName: "fixture")
        try await c1.start()
        _ = try await c1.runOnce()
        let baseline = th(try await store1.rowCounts())["file_changes"] ?? 0

        let store2 = try DiskTraceStore(path: path)
        let c2 = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0), store: store2,
            scanner: FixtureScanner(), sampler: VolumeSampler(fixedFree: normalFree),
            scannerName: "fixture")
        try await c2.start()
        _ = try await c2.runOnce()
        let after = th(try await store2.rowCounts())["file_changes"] ?? 0
        #expect(after == baseline)
    }

    @Test("RE02/LS06: changes during downtime are a recovery window, not a precise write")
    func restartRecovery() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-re02-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path

        let store1 = try DiskTraceStore(path: path)
        let c1 = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0), store: store1,
            scanner: FixtureScanner(), sampler: VolumeSampler(fixedFree: normalFree),
            scannerName: "fixture")
        try await c1.start()
        _ = try await c1.runOnce()

        // While "stopped", a file appears.
        try Data(repeating: 0x42, count: 16384).write(to: root.appending(path: "offline.bin"))

        let store2 = try DiskTraceStore(path: path)
        let c2 = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0), store: store2,
            scanner: FixtureScanner(), sampler: VolumeSampler(fixedFree: normalFree),
            scannerName: "fixture")
        try await c2.start()
        _ = try await c2.runOnce()

        let rootID = MonitoredRoot.stableID(canonicalPath: FilePaths.canonical(root.path))
        let changes = try await store2.fileChanges(
            rootID: rootID, from: Date().addingTimeInterval(-600), to: Date().addingTimeInterval(600),
            limit: 100)
        let added = changes.first { $0.pathAfter == FilePaths.canonical(root.path) + "/offline.bin" }
        #expect(added != nil)
        #expect(added?.timing == .recoveryWindow)
    }
}

/// Helper to read rowCounts without pulling the actor across await boundaries twice.
private func th(_ counts: [String: Int]) -> [String: Int] { counts }
