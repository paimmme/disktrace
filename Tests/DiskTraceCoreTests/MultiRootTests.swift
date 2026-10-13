import Foundation
import Testing

@testable import DiskTraceCore

private func now() -> Date { Date() }

private func file(_ path: String, _ id: String, _ bytes: Int64) -> FileMetadata {
    FileMetadata(
        path: path, fileIdentity: id, kind: .regularFile, logicalBytes: bytes,
        allocatedBytes: bytes, modifiedAt: now(), birthAt: now(), observedAt: now(), linkCount: 1)
}

private func publish(
    _ store: DiskTraceStore, root: UUID, files: [FileMetadata], dirs: [String: Int64]
) async throws -> PublishResult {
    let scan = try await store.beginScan(rootID: root, startEventID: nil, at: now())
    try await store.stageInventory(rootID: root, scanID: scan, files: files)
    try await store.stageDirectorySummaries(
        scanID: scan,
        summaries: dirs.map { DirectorySize(path: $0.key, allocatedBytes: $0.value, fileCount: files.count) })
    return try await store.publishScan(rootID: root, scanID: scan, at: now(), complete: true)
}

private func activeScan(_ store: DiskTraceStore, _ root: UUID) async throws -> UUID? {
    try await store.rootHealth(rootID: root)?.activeScanID
}

@Suite("Multi-root isolation (MR-series)")
struct MultiRootTests {
    private func twoRoots(_ store: DiskTraceStore) async throws -> (MonitoredRoot, MonitoredRoot) {
        let a = try await store.ensureRoot(
            canonicalPath: "/rootA", volumeID: "v", configRevision: 1, at: now())
        let b = try await store.ensureRoot(
            canonicalPath: "/rootB", volumeID: "v", configRevision: 1, at: now())
        return (a, b)
    }

    @Test("MR01: publishing root B keeps root A's summaries")
    func publishBKeepsA() async throws {
        let store = try DiskTraceStore.inMemory()
        let (a, b) = try await twoRoots(store)
        _ = try await publish(store, root: a.id, files: [file("/rootA/x", "1", 100)], dirs: ["/rootA": 100])
        _ = try await publish(store, root: b.id, files: [file("/rootB/y", "2", 200)], dirs: ["/rootB": 200])
        let aScan = try #require(try await activeScan(store, a.id))
        let bScan = try #require(try await activeScan(store, b.id))
        #expect(try await store.directorySummaries(scanID: aScan).keys.contains("/rootA"))
        #expect(try await store.directorySummaries(scanID: bScan).keys.contains("/rootB"))
    }

    @Test("MR02: 20 alternating publishes stay isolated and consistent")
    func alternating() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-mr02-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DiskTraceStore(path: dir.appending(path: "db.sqlite").path)
        let (a, b) = try await twoRoots(store)
        for index in 0..<20 {
            _ = try await publish(
                store, root: a.id, files: [file("/rootA/x", "1", Int64(100 + index))], dirs: ["/rootA": Int64(100 + index)])
            _ = try await publish(
                store, root: b.id, files: [file("/rootB/y", "2", Int64(200 + index))], dirs: ["/rootB": Int64(200 + index)])
        }
        let aScan = try #require(try await activeScan(store, a.id))
        let bScan = try #require(try await activeScan(store, b.id))
        #expect(try await store.inventoryCount(rootID: a.id, scanID: aScan) == 1)
        #expect(try await store.inventoryCount(rootID: b.id, scanID: bScan) == 1)
        #expect(try await store.directorySummaries(scanID: aScan)["/rootA"] == 119)
        #expect(try await store.directorySummaries(scanID: bScan)["/rootB"] == 219)
        #expect(try await store.integrityCheck() == ["ok"])
        #expect(try await store.foreignKeyViolations().isEmpty)
    }

    @Test("MR03: root B failure does not disturb root A's active generation")
    func failedScanKeepsA() async throws {
        let store = try DiskTraceStore.inMemory()
        let (a, b) = try await twoRoots(store)
        _ = try await publish(store, root: a.id, files: [file("/rootA/x", "1", 100)], dirs: ["/rootA": 100])
        let aScan = try #require(try await activeScan(store, a.id))
        // B scans then fails mid-way.
        let bScan = try await store.beginScan(rootID: b.id, startEventID: nil, at: now())
        try await store.stageInventory(rootID: b.id, scanID: bScan, files: [file("/rootB/y", "2", 200)])
        try await store.failScan(rootID: b.id, scanID: bScan, reason: "cancelled", state: .needsRebaseline, at: now())
        #expect(try await activeScan(store, a.id) == aScan)
        #expect(try await store.directorySummaries(scanID: aScan)["/rootA"] == 100)
        #expect(try await store.inventoryCount(rootID: a.id, scanID: aScan) == 1)
    }

    @Test("MR04: same relative subdirectory in two roots never shares data")
    func sameRelativePath() async throws {
        let store = try DiskTraceStore.inMemory()
        let (a, b) = try await twoRoots(store)
        _ = try await publish(store, root: a.id, files: [file("/rootA/sub/x", "1", 100)], dirs: ["/rootA/sub": 100])
        _ = try await publish(store, root: b.id, files: [file("/rootB/sub/y", "2", 900)], dirs: ["/rootB/sub": 900])
        let aScan = try #require(try await activeScan(store, a.id))
        let bScan = try #require(try await activeScan(store, b.id))
        #expect(try await store.directorySummaries(scanID: aScan) == ["/rootA/sub": 100])
        #expect(try await store.directorySummaries(scanID: bScan) == ["/rootB/sub": 900])
    }

    @Test("MR05: a reopened store keeps roots isolated")
    func reopened() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-mr05-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        var store = try DiskTraceStore(path: path)
        let (a, b) = try await twoRoots(store)
        _ = try await publish(store, root: a.id, files: [file("/rootA/x", "1", 100)], dirs: ["/rootA": 100])
        let aScan = try #require(try await activeScan(store, a.id))
        // Reopen and publish B.
        store = try DiskTraceStore(path: path)
        let bRecord = try await store.ensureRoot(
            canonicalPath: "/rootB", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, root: bRecord.id, files: [file("/rootB/y", "2", 200)], dirs: ["/rootB": 200])
        #expect(try await store.directorySummaries(scanID: aScan)["/rootA"] == 100)
    }

    @Test("MR06: removing a subdir in root A leaves root B untouched")
    func removalIsolated() async throws {
        let store = try DiskTraceStore.inMemory()
        let (a, b) = try await twoRoots(store)
        _ = try await publish(
            store, root: a.id,
            files: [file("/rootA/sub/x", "1", 500)], dirs: ["/rootA": 500, "/rootA/sub": 500])
        _ = try await publish(store, root: b.id, files: [file("/rootB/y", "2", 700)], dirs: ["/rootB": 700])
        // A loses /rootA/sub.
        let result = try await publish(store, root: a.id, files: [], dirs: ["/rootA": 0])
        #expect(result.fileChanges.contains { $0.kind == .removed && $0.pathBefore == "/rootA/sub/x" })
        #expect(result.directoryDeltas.contains { $0.pathID == "/rootA/sub" && $0.deltaAllocatedBytes == -500 })
        let bScan = try #require(try await activeScan(store, b.id))
        #expect(try await store.directorySummaries(scanID: bScan)["/rootB"] == 700)
    }
}
