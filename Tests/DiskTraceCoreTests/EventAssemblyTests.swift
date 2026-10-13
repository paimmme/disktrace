import Foundation
import Testing

@testable import DiskTraceCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func change(
    root: UUID, path: String, delta: Int64, kind: FileChangeKind = .added,
    at date: Date = t0.addingTimeInterval(30)
) -> FileChange {
    FileChange(
        id: FileChange.stableID(
            evidenceVersion: 1, rootID: root, identityBefore: nil, identityAfter: "id",
            pathBefore: nil, pathAfter: path, locator: path),
        rootID: root, scanID: nil, pathBefore: nil, pathAfter: path, identityBefore: nil,
        identityAfter: "id", kind: kind, windowStart: t0, windowEnd: t0.addingTimeInterval(60),
        observedAt: date, beforeLogical: nil, afterLogical: nil, beforeAllocated: nil,
        afterAllocated: delta, deltaAllocated: delta, measurement: .measured,
        timing: .scanWindow, evidenceVersion: 1)
}

private func activity(id: UUID, cwd: String, start: Date = t0, end: Date? = t0.addingTimeInterval(50), bounded: Bool = true) -> AgentActivity {
    AgentActivity(
        id: id, sessionIDHash: "session", client: .codexDesktop, startedAt: start, endedAt: end,
        workingDirectory: cwd, taskIDHash: "task", windowIsTaskBounded: bounded)
}

private func window(id: UUID, cwd: String, verification: VerificationState = .realClientVerified, lifecycle: TaskLifecycleState = .completed) -> TaskWindow {
    TaskWindow(
        activityID: id, sessionHash: "session", taskHash: "task", clientKind: .codexDesktop,
        clientVersion: "1", lifecycle: lifecycle, startKnown: true, endKnown: true,
        lastEventAt: t0.addingTimeInterval(50), schemaKind: "codex-envelope",
        verification: verification, sourceLogPath: "/log")
}

@Suite("Event assembly & attribution (E-series)")
struct EventAssemblyTests {
    private let root = UUID()

    @Test("E01: a project task keeps its candidate without being swallowed by the root")
    func projectCandidate() {
        let id = UUID()
        let assembled = EventAssembler.assemble(
            changes: [change(root: root, path: "/fixture/project/src/a.bin", delta: 200_000_000)],
            windows: [window(id: id, cwd: "/fixture/project")],
            activities: [id: activity(id: id, cwd: "/fixture/project")],
            roots: [root: "/fixture"], configRevision: 1, now: t0.addingTimeInterval(60))
        #expect(assembled.count == 1)
        let event = assembled[0].event
        #expect(event.scopePath == "/fixture/project")
        #expect(event.attributionClass == .agentProbable)
        #expect(assembled[0].links.contains { $0.state == .pathCandidate })
        #expect(event.reasonCategory == .unknown)
    }

    @Test("E02: project and Downloads produce two events; Downloads stays unknown")
    func projectAndDownloads() {
        let id = UUID()
        let assembled = EventAssembler.assemble(
            changes: [
                change(root: root, path: "/fixture/project/src/a.bin", delta: 200_000_000),
                change(root: root, path: "/fixture/Downloads/big.dmg", delta: 100_000_000),
            ],
            windows: [window(id: id, cwd: "/fixture/project")],
            activities: [id: activity(id: id, cwd: "/fixture/project")],
            roots: [root: "/fixture"], configRevision: 1, now: t0.addingTimeInterval(60))
        #expect(assembled.count == 2)
        let downloads = assembled.first { $0.event.scopePath == "/fixture/Downloads" }
        #expect(downloads?.event.reasonCategory == .downloadsFolder)
        #expect(downloads?.event.attributionClass == .unknown)
        #expect(downloads?.links.allSatisfy { $0.state == .timeOnly } == true)
    }

    @Test("E03: two tasks in the same scope are ambiguous, never the most recent")
    func ambiguous() {
        let a = UUID(), b = UUID()
        let assembled = EventAssembler.assemble(
            changes: [change(root: root, path: "/fixture/project/x", delta: 300_000_000)],
            windows: [window(id: a, cwd: "/fixture/project"), window(id: b, cwd: "/fixture/project")],
            activities: [
                a: activity(id: a, cwd: "/fixture/project"),
                b: activity(id: b, cwd: "/fixture/project"),
            ],
            roots: [root: "/fixture"], configRevision: 1, now: t0.addingTimeInterval(60))
        let event = assembled[0].event
        #expect(event.attributionClass == .unknown)
        #expect(assembled[0].links.allSatisfy { $0.state == .ambiguous })
    }

    @Test("E04: time overlap with a different directory is timeOnly")
    func timeOnly() {
        let id = UUID()
        let assembled = EventAssembler.assemble(
            changes: [change(root: root, path: "/fixture/project/z", delta: 300_000_000)],
            windows: [window(id: id, cwd: "/fixture/other")],
            activities: [id: activity(id: id, cwd: "/fixture/other")],
            roots: [root: "/fixture"], configRevision: 1, now: t0.addingTimeInterval(60))
        #expect(assembled[0].event.attributionClass == .unknown)
        #expect(assembled[0].links.allSatisfy { $0.state == .timeOnly })
    }

    @Test("E05: a cache outside the cwd is classified but its source stays unknown")
    func cacheOutsideCwd() {
        let assembled = EventAssembler.assemble(
            changes: [change(root: root, path: "/root/.cache/huggingface/model.bin", delta: 5_000_000_000)],
            windows: [], activities: [:], roots: [root: "/root"], configRevision: 1,
            now: t0.addingTimeInterval(60))
        #expect(assembled[0].event.reasonCategory == .modelCache)
        #expect(assembled[0].event.attributionClass == .unknown)
    }

    @Test("E08: a node_modules name hint with huge growth is still unknown")
    func nameHintStillUnknown() {
        let assembled = EventAssembler.assemble(
            changes: [change(root: root, path: "/root/node_modules/pkg/index.js", delta: 9_000_000_000)],
            windows: [], activities: [:], roots: [root: "/root"], configRevision: 1,
            now: t0.addingTimeInterval(60))
        #expect(assembled[0].event.reasonCategory == .dependencies)
        #expect(assembled[0].event.attributionClass == .unknown)
    }

    @Test("E11: user confirmation sets userConfirmed; revoke restores unknown")
    func userFeedback() async throws {
        let store = try DiskTraceStore.inMemory()
        let rootRecord = try await store.ensureRoot(
            canonicalPath: "/fixture", volumeID: "v", configRevision: 1, at: t0)
        let id = UUID()
        let ch = change(root: rootRecord.id, path: "/fixture/project/x", delta: 10)
        let act = activity(id: id, cwd: "/fixture/project")
        let assembled = EventAssembler.assemble(
            changes: [ch],
            windows: [window(id: id, cwd: "/fixture/project", verification: .unverified)],
            activities: [id: act],
            roots: [rootRecord.id: "/fixture"], configRevision: 1, now: t0.addingTimeInterval(60))
        try await store.insert(act)
        try await store.insertFileChange(ch)
        try await store.upsertEvents(assembled, at: t0)
        let eventID = assembled[0].event.id
        try await store.addEventFeedback(eventID: eventID, kind: "confirmUser", at: t0)
        let confirmed = try await store.queryEvents(rootID: nil, from: t0, to: t0.addingTimeInterval(600))
        #expect(confirmed.first?.attributionClass == .userConfirmed)
        try await store.revokeEventFeedback(eventID: eventID, at: t0.addingTimeInterval(10))
        let revoked = try await store.queryEvents(rootID: nil, from: t0, to: t0.addingTimeInterval(600))
        #expect(revoked.first?.attributionClass == .unknown)
    }

    @Test("E12: presence checks report present, replaced and missing honestly")
    func presenceChecks() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-presence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "keep.bin")
        try Data(repeating: 0x41, count: 100).write(to: file)
        let probe = MetadataProbe()
        let present = try probe.probe(file.path).get()

        // Present with matching identity.
        switch probe.probe(file.path) {
        case .success(let m): #expect(m.fileIdentity == present.fileIdentity)
        case .failure: Issue.record("expected present")
        }
        // Replaced: rewrite with a different inode.
        try? FileManager.default.removeItem(at: file)
        try Data(repeating: 0x42, count: 100).write(to: file)
        if case .success(let m) = probe.probe(file.path) {
            #expect(m.fileIdentity != present.fileIdentity)
        }
        // Missing.
        try? FileManager.default.removeItem(at: file)
        switch probe.probe(file.path) {
        case .failure(.notFound): break
        default: Issue.record("expected notFound")
        }
    }
}
