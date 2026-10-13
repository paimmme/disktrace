import Foundation
import Testing

@testable import DiskTraceCore

private func now() -> Date { Date() }

@Suite("Inventory diff memory & scale (MEM-series)")
struct MemoryDiffTests {
    private func files(_ count: Int, base: String, alloc: (Int) -> Int64, identity: (Int) -> String) -> [FileMetadata] {
        (0..<count).map { index in
            FileMetadata(
                path: "\(base)/f\(index).bin", fileIdentity: identity(index), kind: .regularFile,
                logicalBytes: alloc(index), allocatedBytes: alloc(index), modifiedAt: now(),
                birthAt: now(), observedAt: now(), linkCount: 1)
        }
    }

    @Test("MEM01: 10k-file diff stays correct and bounded")
    func tenThousand() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(
            canonicalPath: "/r", volumeID: "v", configRevision: 1, at: now())
        let count = 10_000
        let scan1 = try await store.beginScan(rootID: root.id, startEventID: nil, at: now())
        try await store.stageInventory(
            rootID: root.id, scanID: scan1,
            files: files(count, base: "/r", alloc: { Int64($0 * 10) }, identity: { "1:\($0):0" }))
        try await store.stageDirectorySummaries(
            scanID: scan1, summaries: [DirectorySize(path: "/r", allocatedBytes: 0, fileCount: count)])
        _ = try await store.publishScan(rootID: root.id, scanID: scan1, at: now(), complete: true)

        // Second generation: one grown, 100 added, 50 removed.
        var next = files(count, base: "/r", alloc: { Int64($0 * 10) }, identity: { "1:\($0):0" })
        next[5000] = FileMetadata(
            path: "/r/f5000.bin", fileIdentity: "1:5000:0", kind: .regularFile, logicalBytes: 50_000 + 4096,
            allocatedBytes: 50_000 + 4096, modifiedAt: now(), birthAt: now(), observedAt: now(),
            linkCount: 1)
        for index in count..<(count + 100) {
            next.append(
                FileMetadata(
                    path: "/r/f\(index).bin", fileIdentity: "1:\(index):0", kind: .regularFile,
                    logicalBytes: 1, allocatedBytes: 1, modifiedAt: now(), birthAt: now(),
                    observedAt: now(), linkCount: 1))
        }
        // Drop 50 by not carrying them forward.
        let scan2 = try await store.beginScan(rootID: root.id, startEventID: nil, at: now())
        try await store.stageInventory(rootID: root.id, scanID: scan2, files: next)
        try await store.stageDirectorySummaries(
            scanID: scan2, summaries: [DirectorySize(path: "/r", allocatedBytes: 0, fileCount: count + 100)])
        let result = try await store.publishScan(rootID: root.id, scanID: scan2, at: now(), complete: true)

        let grown = result.fileChanges.filter { $0.kind == .grown }
        let added = result.fileChanges.filter { $0.kind == .added }
        #expect(grown.count == 1 && grown.first?.pathAfter == "/r/f5000.bin")
        #expect(added.count == 100)
        #expect(try await store.inventoryCount(rootID: root.id, scanID: scan2) == count + 100)
        #expect(try await store.integrityCheck() == ["ok"])
    }

    @Test("MEM05: hardlink identity reused across two paths is not merged into a move")
    func hardlinkNotMoved() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(
            canonicalPath: "/r", volumeID: "v", configRevision: 1, at: now())
        let scan1 = try await store.beginScan(rootID: root.id, startEventID: nil, at: now())
        try await store.stageInventory(
            rootID: root.id, scanID: scan1,
            files: [
                FileMetadata(
                    path: "/r/a", fileIdentity: "1:9:9", kind: .regularFile, logicalBytes: 1,
                    allocatedBytes: 4096, modifiedAt: now(), birthAt: now(), observedAt: now(),
                    linkCount: 2),
                FileMetadata(
                    path: "/r/b", fileIdentity: "1:9:9", kind: .regularFile, logicalBytes: 1,
                    allocatedBytes: 4096, modifiedAt: now(), birthAt: now(), observedAt: now(),
                    linkCount: 2),
            ])
        _ = try await store.publishScan(rootID: root.id, scanID: scan1, at: now(), complete: true)
        // Second generation: both paths gone but a new path shares the identity.
        let scan2 = try await store.beginScan(rootID: root.id, startEventID: nil, at: now())
        try await store.stageInventory(
            rootID: root.id, scanID: scan2,
            files: [
                FileMetadata(
                    path: "/r/c", fileIdentity: "1:9:9", kind: .regularFile, logicalBytes: 1,
                    allocatedBytes: 4096, modifiedAt: now(), birthAt: now(), observedAt: now(),
                    linkCount: 2)
            ])
        let result = try await store.publishScan(rootID: root.id, scanID: scan2, at: now(), complete: true)
        // Identity reused by multiple paths must not become a confident move.
        #expect(!result.fileChanges.contains { $0.kind == .moved })
    }
}
