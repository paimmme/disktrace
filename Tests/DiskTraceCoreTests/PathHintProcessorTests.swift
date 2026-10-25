import Foundation
import Testing

@testable import DiskTraceCore

@Suite("Path hint processor")
struct PathHintProcessorTests {
    @Test("coalesce drops parent when child is present")
    func coalesce() {
        let paths = ["/root", "/root/a/file.bin", "/other/x"]
        let result = PathHintProcessor.coalescePaths(paths)
        #expect(result.contains("/root/a/file.bin"))
        #expect(!result.contains("/root"))
        #expect(result.contains("/other/x"))
    }

    @Test("added file with no baseline is beforeUnknown")
    func addedUnknownBaseline() {
        let root = UUID()
        let meta = FileMetadata(
            path: "/r/f", fileIdentity: "1:1:1", kind: .regularFile, logicalBytes: 100,
            allocatedBytes: 4_096, modifiedAt: Date(), birthAt: Date(), observedAt: Date(),
            linkCount: 1)
        let outcome = PathHintProcessor.process(
            path: "/r/f", probe: .success(meta), previous: nil, rootID: root,
            activeScanID: UUID(), windowStart: Date(), observedAt: Date(), hintKey: "k")
        #expect(outcome.change?.kind == .added)
        #expect(outcome.change?.measurement == .beforeUnknown)
        #expect(outcome.change?.timing == .liveHintWindow)
    }

    @Test("grown file computes delta")
    func grown() {
        let root = UUID()
        let before = FileMetadata(
            path: "/r/f", fileIdentity: "1:1:1", kind: .regularFile, logicalBytes: 100,
            allocatedBytes: 4_096, modifiedAt: Date(), birthAt: Date(), observedAt: Date(),
            linkCount: 1)
        let after = FileMetadata(
            path: "/r/f", fileIdentity: "1:1:1", kind: .regularFile, logicalBytes: 200,
            allocatedBytes: 8_192, modifiedAt: Date(), birthAt: Date(), observedAt: Date(),
            linkCount: 1)
        let outcome = PathHintProcessor.process(
            path: "/r/f", probe: .success(after), previous: before, rootID: root,
            activeScanID: UUID(), windowStart: Date(), observedAt: Date(), hintKey: "k")
        #expect(outcome.change?.kind == .grown)
        #expect(outcome.change?.deltaAllocated == 4_096)
    }

    @Test("persist hints enqueue coalesced path work")
    func enqueueWork() async throws {
        let store = try DiskTraceStore.inMemory()
        let root = try await store.ensureRoot(
            canonicalPath: "/root", volumeID: "v", configRevision: 1, at: Date())
        let hint = ChangeHint(eventID: 9, path: "/root/a/file.bin", flag: .created, observedAt: Date())
        try await store.persistHints(
            rootID: root.id, volumeID: "v", eventID: 9, hints: [hint], checkpoint: 9,
            volumeIdentity: "v", at: Date())
        let due = try await store.duePathWork(limit: 10, now: Date().addingTimeInterval(1))
        #expect(due.contains { $0.path == "/root/a/file.bin" })
    }
}
