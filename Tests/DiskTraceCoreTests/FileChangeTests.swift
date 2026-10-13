import Foundation
import Testing

@testable import DiskTraceCore

private func now() -> Date { Date() }

private func meta(_ path: String, _ identity: String, allocated: Int64?, logical: Int64? = nil, linkCount: Int = 1) -> FileMetadata {
    FileMetadata(
        path: path, fileIdentity: identity, kind: .regularFile, logicalBytes: logical,
        allocatedBytes: allocated, modifiedAt: now(), birthAt: now(), observedAt: now(),
        linkCount: linkCount)
}

@Suite("File change diff (D-series)")
struct FileChangeTests {
    private func publish(
        _ store: DiskTraceStore, rootID: UUID, files: [FileMetadata]
    ) async throws -> PublishResult {
        let scanID = try await store.beginScan(rootID: rootID, startEventID: nil, at: now())
        try await store.stageInventory(rootID: rootID, scanID: scanID, files: files)
        // Emit a root directory summary so directory deltas are also covered.
        var total: Int64 = 0
        for file in files { total += file.allocatedBytes ?? 0 }
        try await store.stageDirectorySummaries(
            scanID: scanID, summaries: [DirectorySize(path: "/root", allocatedBytes: total, fileCount: files.count)])
        return try await store.publishScan(rootID: rootID, scanID: scanID, at: now(), complete: true)
    }

    @Test("D01: first complete scan is a baseline with no changes")
    func baseline() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        let result = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 100)])
        #expect(result.state == .baseline)
        #expect(result.fileChanges.isEmpty)
    }

    @Test("D02: a new file after a baseline is recorded as added with its path and size")
    func added() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 100)])
        let result = try await publish(
            store, rootID: root.id,
            files: [meta("/root/a", "1:1:1", allocated: 100), meta("/root/b", "2:2:2", allocated: 4096)])
        let added = try #require(result.fileChanges.first { $0.kind == .added })
        #expect(added.pathAfter == "/root/b")
        #expect(added.afterAllocated == 4096)
        #expect(added.deltaAllocated == 4096)
    }

    @Test("D03: growth then shrink produce signed changes")
    func grownShrunk() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 100)])
        let grown = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 500)])
        #expect(grown.fileChanges.contains { $0.kind == .grown && $0.deltaAllocated == 400 })
        let shrunk = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 150)])
        #expect(shrunk.fileChanges.contains { $0.kind == .shrunk && $0.deltaAllocated == -350 })
    }

    @Test("D04: deleting a subtree records negative change for every path")
    func removedSubtree() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(
            store, rootID: root.id,
            files: [
                meta("/root/a", "1:1:1", allocated: 10), meta("/root/a/x", "2:2:2", allocated: 20),
                meta("/root/a/y", "3:3:3", allocated: 30),
            ])
        let result = try await publish(store, rootID: root.id, files: [])
        let removedPaths = Set(result.fileChanges.filter { $0.kind == .removed }.map(\.pathBefore))
        #expect(removedPaths == Set(["/root/a", "/root/a/x", "/root/a/y"]))
        #expect(result.fileChanges.filter { $0.kind == .removed }.allSatisfy { $0.deltaAllocated ?? 0 < 0 })
    }

    @Test("D05: same path, different identity is replaced, not grown")
    func replaced() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:1:1", allocated: 100)])
        let result = try await publish(store, rootID: root.id, files: [meta("/root/a", "1:9:9", allocated: 100)])
        #expect(result.fileChanges.contains { $0.kind == .replaced && $0.identityAfter == "1:9:9" })
    }

    @Test("D06: same identity rename is one moved change, net zero")
    func moved() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, rootID: root.id, files: [meta("/root/old", "1:1:1", allocated: 2048)])
        let result = try await publish(store, rootID: root.id, files: [meta("/root/new", "1:1:1", allocated: 2048)])
        let moved = try #require(result.fileChanges.first { $0.kind == .moved })
        #expect(moved.pathBefore == "/root/old")
        #expect(moved.pathAfter == "/root/new")
        #expect(moved.deltaAllocated == 0)
        #expect(result.fileChanges.count == 1)
    }

    @Test("D07: hard-linked paths keep a shared identity")
    func hardLinks() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(
            store, rootID: root.id,
            files: [
                meta("/root/p1", "1:5:5", allocated: 4096, linkCount: 2),
                meta("/root/p2", "1:5:5", allocated: 4096, linkCount: 2),
            ])
        let result = try await publish(store, rootID: root.id, files: [])
        let identities = Set(result.fileChanges.compactMap(\.identityBefore))
        #expect(identities == ["1:5:5"])
    }

    @Test("D16: a file created and removed between scans yields no file change")
    func ephemeralFile() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        _ = try await publish(store, rootID: root.id, files: [])
        let result = try await publish(store, rootID: root.id, files: [])
        #expect(result.fileChanges.isEmpty)
    }

    @Test("D17: persisting the same hint twice is idempotent")
    func hintIdempotent() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(canonicalPath: "/root", volumeID: "v", configRevision: 1, at: now())
        let hint = ChangeHint(eventID: 7, path: "/root/a", flag: .created, observedAt: now())
        try await store.persistHints(
            rootID: root.id, volumeID: "v", eventID: 7, hints: [hint], checkpoint: 7,
            volumeIdentity: "v", at: now())
        try await store.persistHints(
            rootID: root.id, volumeID: "v", eventID: 7, hints: [hint], checkpoint: 7,
            volumeIdentity: "v", at: now())
        #expect(try await store.pendingHintCount() == 1)
    }

    @Test("D08: symlinks are recorded but never followed outside the root")
    func symlinkNotFollowed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"), withDestinationURL: URL(filePath: "/etc/passwd"))
        try Data(repeating: 0x41, count: 100).write(to: root.appending(path: "real.bin"))

        let collector = EntryCollector()
        _ = try await FixtureScanner().scanEntries(
            root: root, excluding: [], limits: .default
        ) { entry in collector.record(entry) }
        #expect(collector.paths.contains(where: { $0.hasSuffix("/link") }))
        #expect(!collector.paths.contains(where: { $0.hasSuffix("/passwd") }))
    }
}

private final class EntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var paths: [String] {
        lock.lock(); defer { lock.unlock() }; return all
    }
    func record(_ entry: ScanEntry) {
        lock.lock(); defer { lock.unlock() }
        switch entry {
        case .file(let metadata): all.append(metadata.path)
        case .directory(let summary): all.append(summary.path)
        case .inaccessible(let path, _): all.append(path)
        }
    }
}
