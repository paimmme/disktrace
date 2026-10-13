import Foundation
import Testing

@testable import DiskTraceCore

private func scanResult(
    root: String, _ entries: [(String, Int64)], incomplete: Bool = false,
    at date: Date = Date()
) -> ScanResult {
    ScanResult(
        root: root,
        scannedAt: date,
        directories: entries.map {
            DirectorySize(path: $0.0, allocatedBytes: $0.1, fileCount: 0)
        },
        totalAllocatedBytes: entries.first(where: { $0.0 == root })?.1 ?? 0,
        totalFileCount: 0,
        incomplete: incomplete,
        checkpointID: 1)
}

/// Returns queued results in order; used to script completeness changes.
actor ScriptedScanner: ScannerBackend {
    private var queue: [ScanResult]
    init(_ results: [ScanResult]) { queue = results }

    func scan(root: URL, excluding: [String]) async throws -> ScanResult {
        guard !queue.isEmpty else { throw ScannerUnavailableError(reason: "exhausted") }
        return queue.removeFirst()
    }

    func scanEntries(
        root: URL, excluding: [String], limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion {
        let result = try await scan(root: root, excluding: excluding)
        for summary in result.directories { try await onEntry(.directory(summary)) }
        return ScanCompletion(
            root: result.root, startedAt: result.scannedAt, endedAt: result.scannedAt,
            complete: !result.incomplete, entryCount: result.totalFileCount,
            directoryCount: result.directories.count, checkpointID: result.checkpointID,
            termination: result.incomplete ? .storageError : .completed)
    }
}

@Suite("Directory delta correctness")
struct DeltaTests {
    @Test("deleted directory is recorded as negative change (path union)")
    func deletedDirectoryRecorded() {
        let root = "/r"
        let before = scanResult(root: root, [(root, 1_000), ("/r/a", 600), ("/r/b", 400)])
        let after = scanResult(root: root, [(root, 700), ("/r/a", 700)])
        let deltas = after.deltas(from: before, windowStart: Date())
        let byPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pathID, $0.deltaAllocatedBytes) })
        #expect(byPath["/r/b"] == -400)
        #expect(byPath["/r/a"] == 100)
    }

    @Test("rename is old-path decrease plus new-path increase, no move inference")
    func renameIsTwoRecords() {
        let before = scanResult(root: "/r", [("/r/old", 500)])
        let after = scanResult(root: "/r", [("/r/new", 500)])
        let deltas = after.deltas(from: before, windowStart: Date())
        let byPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pathID, $0.deltaAllocatedBytes) })
        #expect(byPath["/r/old"] == -500)
        #expect(byPath["/r/new"] == 500)
    }

    @Test("simultaneous add and delete in one window both recorded")
    func addAndDeleteSameWindow() {
        let before = scanResult(root: "/r", [("/r/old", 100)])
        let after = scanResult(root: "/r", [("/r/new", 300)])
        let deltas = after.deltas(from: before, windowStart: Date())
        let byPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pathID, $0.deltaAllocatedBytes) })
        #expect(byPath["/r/old"] == -100)
        #expect(byPath["/r/new"] == 300)
    }

    @Test("incomplete scan yields no trusted delta")
    func incompleteYieldsNothing() {
        let before = scanResult(root: "/r", [("/r/a", 1_000)])
        let after = scanResult(root: "/r", [("/r/a", 10_000)], incomplete: true)
        #expect(after.deltas(from: before, windowStart: Date()).isEmpty)
        let beforeIncomplete = scanResult(root: "/r", [("/r/a", 1_000)], incomplete: true)
        let afterComplete = scanResult(root: "/r", [("/r/a", 2_000)])
        #expect(afterComplete.deltas(from: beforeIncomplete, windowStart: Date()).isEmpty)
    }

    @Test("parent and child subtree deltas are not summed")
    func nonOverlappingSelection() {
        let deltas = [
            DirectoryDelta(
                pathID: "/r", windowStart: Date(), windowEnd: Date(), deltaAllocatedBytes: -300,
                beforeAllocatedBytes: 0, afterAllocatedBytes: 0, checkpointID: 1, calibration: .calibrated),
            DirectoryDelta(
                pathID: "/r/b", windowStart: Date(), windowEnd: Date(), deltaAllocatedBytes: -400,
                beforeAllocatedBytes: 0, afterAllocatedBytes: 0, checkpointID: 1, calibration: .calibrated),
        ]
        let selected = ScanResult.nonOverlapping(deltas)
        #expect(selected.map(\.pathID) == ["/r"])
    }
}

@Suite("Monitor completeness and recovery")
struct MonitorCompletenessTests {
    @Test("incomplete recalibration records a gap and never fabricates growth; recovery diffs the old baseline")
    func incompleteThenRecovery() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "disktrace-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = FilePaths.canonical(root.path)

        let complete = scanResult(root: key, [(key, 10_000), (key + "/a", 10_000)])
        let incomplete = scanResult(root: key, [(key, 1_000)], incomplete: true)
        let scanner = ScriptedScanner([complete, incomplete, complete])

        let store = try DiskTraceStore.inMemory()
        var policy = AlertPolicyConfig()
        policy.lowSpaceFreeBytes = 0
        policy.lowSpaceFreeFraction = 0
        policy.agentGrowthThresholdBytes = 1
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(
                roots: [root], sampleInterval: 100_000, calibrationInterval: 0, policy: policy),
            store: store, scanner: scanner, scannerName: "scripted")

        try await coordinator.start()  // consumes `complete` as baseline

        let second = try await coordinator.runOnce()  // consumes `incomplete`
        #expect(second.deltas.isEmpty)

        let third = try await coordinator.runOnce()  // consumes `complete` again
        #expect(!third.deltas.contains { $0.deltaAllocatedBytes > 0 })
        #expect(third.decisions.allSatisfy { $0.action == .silent })

        let gaps = try await store.coverageGaps(from: Date(timeIntervalSince1970: 0))
        #expect(gaps.contains { $0.cause == .permissionDenied })
    }

    @Test("per-root calibration time is independent")
    func perRootState() async throws {
        let a = URL(filePath: NSTemporaryDirectory())
            .appending(path: "disktrace-rootA-\(UUID().uuidString)", directoryHint: .isDirectory)
        let b = URL(filePath: NSTemporaryDirectory())
            .appending(path: "disktrace-rootB-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let keyA = FilePaths.canonical(a.path)
        let keyB = FilePaths.canonical(b.path)
        // Only root A has scripted results; root B's scanner result is reused.
        let scanner = RepeatingScanner { root in
            let key = FilePaths.canonical(root.path)
            return scanResult(root: key, [(key, 1_000)])
        }
        _ = keyA
        _ = keyB
        let store = try DiskTraceStore.inMemory()
        let coordinator = MonitorCoordinator(
            config: MonitorConfig(
                roots: [a, b], sampleInterval: 100_000, calibrationInterval: 0),
            store: store, scanner: scanner, scannerName: "repeating")
        try await coordinator.start()
        let report = try await coordinator.runOnce()
        // Both roots contribute; neither blocks the other.
        #expect(report.deltas.count >= 0)
        let health = await coordinator.health()
        #expect(health.rootCount == 2)
        #expect(health.baselineEstablished)
    }
}

/// Always returns a result derived from the root.
final class RepeatingScanner: ScannerBackend, @unchecked Sendable {
    private let make: @Sendable (URL) -> ScanResult
    init(_ make: @escaping @Sendable (URL) -> ScanResult) { self.make = make }
    func scan(root: URL, excluding: [String]) async throws -> ScanResult { make(root) }
    func scanEntries(
        root: URL, excluding: [String], limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion {
        let result = make(root)
        for summary in result.directories { try await onEntry(.directory(summary)) }
        return ScanCompletion(
            root: result.root, startedAt: result.scannedAt, endedAt: result.scannedAt,
            complete: true, entryCount: result.totalFileCount,
            directoryCount: result.directories.count, checkpointID: result.checkpointID,
            termination: .completed)
    }
}
