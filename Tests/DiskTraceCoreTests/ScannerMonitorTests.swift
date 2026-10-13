import Foundation
import Testing

@testable import DiskTraceCore

private func tempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-scan-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeFile(_ url: URL, bytes: Int) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

@Suite("Fixture scanner")
struct FixtureScannerTests {
    @Test("computes subtree allocated sizes and file counts")
    func subtreeSizes() async throws {
        let root = try tempDirectory("tree")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appending(path: "a/f1.bin"), bytes: 1_000)
        try writeFile(root.appending(path: "b/f2.bin"), bytes: 2_000)
        try writeFile(root.appending(path: "f0.bin"), bytes: 500)

        let result = try await FixtureScanner().scan(root: root, excluding: [])
        #expect(result.totalFileCount == 3)
        #expect(result.totalAllocatedBytes >= 3_500)

        let aPath = FilePaths.canonical(root.appending(path: "a").path)
        let rootPath = FilePaths.canonical(root.path)
        let aBytes = try #require(result.allocatedBytes(forPath: aPath))
        let rootBytes = try #require(result.allocatedBytes(forPath: rootPath))
        #expect(aBytes >= 1_000)
        #expect(rootBytes >= aBytes)
        #expect(!result.incomplete)
    }

    @Test("exclusions are honored")
    func exclusions() async throws {
        let root = try tempDirectory("excl")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appending(path: "keep/f.bin"), bytes: 1_000)
        try writeFile(root.appending(path: "skip/f.bin"), bytes: 4_000)

        let result = try await FixtureScanner().scan(
            root: root, excluding: [root.appending(path: "skip").path])
        #expect(result.totalFileCount == 1)
    }

    @Test("unreadable directories mark the scan incomplete")
    func incompleteOnPermission() async throws {
        let root = try tempDirectory("perm")
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeFile(locked.appending(path: "secret.bin"), bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let result = try await FixtureScanner().scan(root: root, excluding: [])
        #expect(result.incomplete)
    }
}

@Suite("Monitor coordinator (integration)")
struct MonitorCoordinatorTests {
    @Test("records silent deltas, then alerts when an agent activity overlaps")
    func endToEndAttribution() async throws {
        let root = try tempDirectory("monitor")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appending(path: "seed.bin"), bytes: 100)

        let store = try DiskTraceStore.inMemory()
        var policy = AlertPolicyConfig()
        policy.agentGrowthThresholdBytes = 1_000
        // Disable low-space so this machine's <10 GB free does not add noise.
        policy.lowSpaceFreeBytes = 0
        policy.lowSpaceFreeFraction = 0
        let config = MonitorConfig(
            roots: [root], sampleInterval: 0, calibrationInterval: 0,
            changeCapacity: 64, policy: policy)
        let coordinator = MonitorCoordinator(
            config: config, store: store, scanner: FixtureScanner(), scannerName: "fixture")
        try await coordinator.start()
        let rootPath = FilePaths.canonical(root.path)

        // Untracked growth: recorded but silent.
        try writeFile(root.appending(path: "growth-a.bin"), bytes: 200_000)
        let first = try await coordinator.runOnce()
        #expect(first.deltas.contains { $0.pathID == rootPath })
        #expect(first.decisions.allSatisfy { $0.action == .silent })

        // Overlapping agent activity in the same working directory.
        try await store.insert(
            AgentActivity(
                sessionIDHash: "session-1", client: .codexCLI, startedAt: Date(),
                endedAt: Date().addingTimeInterval(60), workingDirectory: rootPath,
                windowIsTaskBounded: true))
        try writeFile(root.appending(path: "growth-b.bin"), bytes: 200_000)
        let second = try await coordinator.runOnce()
        #expect(second.decisions.contains { $0.action == .notifyAgentAnomaly })
        #expect(second.decisions.contains { $0.evidenceClass == .agentProbable })
    }

    @Test("unavailable scanner records a coverage gap instead of fabricating data")
    func scannerUnavailableRecordsGap() async throws {
        let root = try tempDirectory("radix")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiskTraceStore.inMemory()
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(roots: [root], sampleInterval: 0, calibrationInterval: 0),
            store: store, scanner: RadixScannerBackend(), scannerName: "radix")
        try await coordinator.start()
        let counts = try await store.rowCounts()
        #expect((counts["coverage_gaps"] ?? 0) >= 1)
        let health = await coordinator.health()
        #expect(health.openGapCount >= 1)
    }

    @Test("explicit gap recording persists")
    func recordGap() async throws {
        let root = try tempDirectory("gap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiskTraceStore.inMemory()
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(roots: [root]), store: store, scannerName: "fixture")
        await coordinator.recordGap(.sleepWake, severity: .medium)
        let gaps = try await store.coverageGaps(from: Date(timeIntervalSince1970: 0))
        #expect(gaps.contains { $0.cause == .sleepWake })
    }
}

@Suite("Change monitor (live FSEvents)")
struct ChangeMonitorTests {
    @Test("captures filesystem writes")
    func capturesWrites() async throws {
        let root = try tempDirectory("changes")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ChangeMonitor(roots: [root], capacity: 64, latency: 0.05)
        try monitor.start()
        defer { monitor.stop() }

        try writeFile(root.appending(path: "a.bin"), bytes: 10)
        try await Task.sleep(for: .milliseconds(400))
        try writeFile(root.appending(path: "b.bin"), bytes: 10)

        var seen = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if monitor.drain().hints.contains(where: { $0.path.hasSuffix("b.bin") }) {
                seen = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen)
    }

    @Test("coalesced queue never exceeds its capacity")
    func boundedQueue() async throws {
        let root = try tempDirectory("bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ChangeMonitor(roots: [root], capacity: 2, latency: 0.02)
        try monitor.start()
        defer { monitor.stop() }

        for index in 0..<40 {
            try writeFile(root.appending(path: "f\(index).bin"), bytes: 10)
        }
        try await Task.sleep(for: .milliseconds(600))
        let output = monitor.drain()
        #expect(output.hints.count <= 2)
    }
}

@Suite("Volume sampler")
struct VolumeSamplerTests {
    @Test("samples the home volume")
    func samplesHome() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let sample = try VolumeSampler().sample(url: url, at: Date())
        #expect(sample.capacityBytes > 0)
        #expect(sample.freeBytes <= sample.capacityBytes)
        #expect(sample.status == .available)
        #expect(!sample.volumeID.isEmpty)
    }
}
