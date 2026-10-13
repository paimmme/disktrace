import Foundation
import Testing

@testable import DiskTraceCore

private func makeHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-env-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: url.appending(path: "sessions/2026/10/13", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    return url
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func metaLine(
    ts: Date, sessionID: String, cwd: String, originator: String? = nil,
    source: String? = nil, version: String? = nil
) -> String {
    var fields = [#""session_id":"\#(sessionID)""#, #""cwd":"\#(cwd)""#]
    if let originator { fields.append(#""originator":"\#(originator)""#) }
    if let source { fields.append(#""source":"\#(source)""#) }
    if let version { fields.append(#""cli_version":"\#(version)""#) }
    return #"{"timestamp":"\#(iso(ts))","type":"session_meta","payload":{\#(fields.joined(separator: ","))}}"#
}

private func evLine(ts: Date, _ type: String, turn: String) -> String {
    #"{"timestamp":"\#(iso(ts))","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
}

private func logURL(_ home: URL, _ name: String) -> URL {
    home.appending(path: "sessions/2026/10/13").appending(path: name)
}

private func writeLog(_ home: URL, _ name: String, _ body: String) throws -> URL {
    let url = logURL(home, name)
    try Data(body.utf8).write(to: url)
    return url
}

private func appendLog(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value
        ?? 0
}

@Suite("Codex real envelope (C-series)")
struct CodexEnvelopeTests {
    @Test("C01: event_msg envelope with turn_id is recognized")
    func realEnvelope() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            [
                metaLine(ts: now, sessionID: "sess-1", cwd: "/tmp/project"),
                evLine(ts: now, "task_started", turn: "turn-1"),
                evLine(ts: now.addingTimeInterval(60), "task_complete", turn: "turn-1"),
            ].joined(separator: "\n") + "\n")

        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(configuration: .init(codexHome: home))
        _ = await sync.sync(store: store, now: now)

        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.lifecycle == .completed)
        #expect(window.startKnown && window.endKnown)
        #expect(window.schemaKind == "codex-envelope")
        let activity = try #require(
            try await store.activities(
                from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400)).first)
        #expect(activity.workingDirectory == "/tmp/project")
        #expect(activity.windowIsTaskBounded)
    }

    @Test("C02: many small syncs eventually read to the last complete line")
    func incrementalToEnd() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let filler = #"{"type":"noop","x":"0123456789abcdef0123456789abcdef"}"# + "\n"
        var body = metaLine(ts: now, sessionID: "s2", cwd: "/tmp/p") + "\n"
        var size = body.utf8.count
        while size < 4800 { body += filler; size += filler.utf8.count }
        let url = try writeLog(home, "rollout.jsonl", body + evLine(
            ts: now, "task_started", turn: "tail") + "\n" + evLine(
            ts: now, "task_complete", turn: "tail") + "\n")

        let store = try DiskTraceStore.inMemory()
        let config = CodexIntegrationConfiguration(
            codexHome: home, byteBudgetPerSync: 256, perFileBudgetBytes: 256)
        let sync = AgentActivitySync(configuration: config)
        var t = now
        for _ in 0..<40 {
            _ = await sync.sync(store: store, now: t)
            t = t.addingTimeInterval(0.05)
        }
        let state = try await store.sessionSyncState(path: FilePaths.canonical(url.path))
        #expect(state?.byteOffset == fileSize(url))
        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.contains { $0.taskHash == windows.first?.taskHash && $0.endKnown })
        #expect(windows.count == 1)
    }

    @Test("C03: reads are bounded by the global budget and never stop early")
    func budgetBounded() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let filler = #"{"type":"noop","y":"0123456789abcdef0123456789abcdef"}"# + "\n"
        var body = metaLine(ts: now, sessionID: "s3", cwd: "/tmp/p") + "\n"
        var size = body.utf8.count
        while size < 200_000 { body += filler; size += filler.utf8.count }
        let url = try writeLog(home, "rollout.jsonl", body)

        let store = try DiskTraceStore.inMemory()
        let budget = 64 * 1024
        let config = CodexIntegrationConfiguration(
            codexHome: home, byteBudgetPerSync: budget, perFileBudgetBytes: budget)
        let sync = AgentActivitySync(configuration: config)
        var t = now
        var done = false
        for _ in 0..<20 {
            let result = await sync.sync(store: store, now: t)
            #expect(result.bytesRead <= budget)
            t = t.addingTimeInterval(0.05)
            let state = try await store.sessionSyncState(path: FilePaths.canonical(url.path))
            if state?.byteOffset == fileSize(url) { done = true; break }
        }
        #expect(done)
    }

    @Test("C04: a half line is re-read after restart and the start appears once")
    func halfLineRestart() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let start = evLine(ts: now, "task_started", turn: "t1")
        let half = String(start.prefix(start.count / 2))
        let url = try writeLog(
            home, "rollout.jsonl", metaLine(ts: now, sessionID: "s4", cwd: "/tmp/p") + "\n" + half)

        let store = try DiskTraceStore(path: try makeHome().appending(path: "db.sqlite").path)
        let config = CodexIntegrationConfiguration(codexHome: home)
        _ = await AgentActivitySync(configuration: config).sync(store: store, now: now)

        // Restart: a fresh sync instance with no in-memory carry.
        try appendLog(url, String(start.dropFirst(half.count)) + "\n")
        _ = await AgentActivitySync(configuration: config)
            .sync(store: store, now: now.addingTimeInterval(1))

        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.count == 1)
        #expect(windows.first?.lifecycle == .running)
    }

    @Test("C06: an oversized complete line is skipped once and later tasks still parse")
    func oversizedCompleteLine() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let huge = #"{"type":"session_meta","payload":{"cwd":"\#(String(repeating: "x", count: 400))"}}"#
        let url = try writeLog(
            home, "rollout.jsonl",
            metaLine(ts: now, sessionID: "s6", cwd: "/tmp/p") + "\n" + huge + "\n"
                + evLine(ts: now, "task_started", turn: "t") + "\n"
                + evLine(ts: now, "task_complete", turn: "t") + "\n")
        _ = url

        let store = try DiskTraceStore.inMemory()
        let config = CodexIntegrationConfiguration(codexHome: home, maxRecordBytes: 128)
        _ = await AgentActivitySync(configuration: config).sync(store: store, now: now)

        let gaps = try await store.coverageGaps(from: now.addingTimeInterval(-86_400))
        #expect(gaps.filter { $0.cause == .oversizedRecord }.count == 1)
        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.count == 1)
    }

    @Test("C07: an oversized partial line is discarded and not parsed after restart")
    func oversizedPartialRestart() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let url = try writeLog(
            home, "rollout.jsonl",
            metaLine(ts: now, sessionID: "s7", cwd: "/tmp/p") + "\n"
                + #"{"type":"event_msg","payload":{"type":"task"# + String(repeating: "z", count: 400))

        let store = try DiskTraceStore(path: try makeHome().appending(path: "db.sqlite").path)
        let config = CodexIntegrationConfiguration(codexHome: home, maxRecordBytes: 128)
        _ = await AgentActivitySync(configuration: config).sync(store: store, now: now)

        // Restart, then finish the record boundary and append a valid task.
        try appendLog(url, "\n" + evLine(ts: now, "task_started", turn: "good") + "\n"
            + evLine(ts: now, "task_complete", turn: "good") + "\n")
        _ = await AgentActivitySync(configuration: config)
            .sync(store: store, now: now.addingTimeInterval(1))

        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.count == 1)
        #expect(windows.first?.endKnown == true)
    }

    @Test("C09: duplicate start/end is idempotent")
    func duplicateIdempotent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            [
                metaLine(ts: now, sessionID: "s9", cwd: "/tmp/p"),
                evLine(ts: now, "task_started", turn: "t"),
                evLine(ts: now, "task_started", turn: "t"),
                evLine(ts: now.addingTimeInterval(5), "task_complete", turn: "t"),
                evLine(ts: now.addingTimeInterval(6), "task_complete", turn: "t"),
            ].joined(separator: "\n") + "\n")
        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(configuration: .init(codexHome: home))
        _ = await sync.sync(store: store, now: now)
        _ = await sync.sync(store: store, now: now.addingTimeInterval(1))
        let counts = try await store.rowCounts()
        #expect(counts["agent_activities"] == 1)
        #expect(counts["task_windows"] == 1)
    }

    @Test("C11: an open task survives restart and keeps its original start")
    func restartKeepsStart() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(120)
        let url = try writeLog(
            home, "rollout.jsonl",
            metaLine(ts: start, sessionID: "s11", cwd: "/tmp/p") + "\n"
                + evLine(ts: start, "task_started", turn: "t") + "\n")
        let store = try DiskTraceStore(path: try makeHome().appending(path: "db.sqlite").path)
        let config = CodexIntegrationConfiguration(codexHome: home)
        _ = await AgentActivitySync(configuration: config).sync(store: store, now: start)

        // Restart, then the task completes.
        try appendLog(url, evLine(ts: end, "task_complete", turn: "t") + "\n")
        _ = await AgentActivitySync(configuration: config)
            .sync(store: store, now: end.addingTimeInterval(1))

        let activity = try #require(
            try await store.activities(from: start.addingTimeInterval(-10), to: end.addingTimeInterval(86_400))
                .first)
        #expect(abs(activity.startedAt.timeIntervalSince(start)) < 0.5)
        #expect(activity.endedAt != nil)
        #expect(activity.windowIsTaskBounded)
    }

    @Test("C12: end without start is unknownStart and not a confident window")
    func endWithoutStart() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            metaLine(ts: now, sessionID: "s12", cwd: "/tmp/p") + "\n"
                + evLine(ts: now, "task_complete", turn: "orphan") + "\n")
        let store = try DiskTraceStore.inMemory()
        _ = await AgentActivitySync(configuration: .init(codexHome: home)).sync(store: store, now: now)
        let window = try #require(try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400)).first)
        #expect(window.lifecycle == .unknownStart)
        #expect(window.startKnown == false)
        #expect(!window.isConfidentCandidate(now: now))
    }

    @Test("C13: two concurrent tasks in one session do not overwrite each other")
    func twoConcurrentTasks() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            [
                metaLine(ts: now, sessionID: "s13", cwd: "/tmp/p"),
                evLine(ts: now, "task_started", turn: "a"),
                evLine(ts: now, "task_started", turn: "b"),
                evLine(ts: now.addingTimeInterval(10), "task_complete", turn: "a"),
                evLine(ts: now.addingTimeInterval(20), "task_complete", turn: "b"),
            ].joined(separator: "\n") + "\n")
        let store = try DiskTraceStore.inMemory()
        _ = await AgentActivitySync(configuration: .init(codexHome: home)).sync(store: store, now: now)
        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.endKnown })
    }

    @Test("C14: decoy cwd/id/type inside message bodies are not read")
    func decoyBodies() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let secret = "SECRET-PROMPT-DO-NOT-STORE"
        let decoy = #"{\"cwd\":\"/evil\",\"session_id\":\"EVIL\",\"type\":\"task_started\"}"#
        let body = #"{"timestamp":"\#(iso(now))","type":"session_meta","payload":{"session_id":"real","cwd":"/tmp/real","message":"\#(secret)","command":"\#(decoy)"}}"#
        _ = try writeLog(
            home, "rollout.jsonl",
            body + "\n" + evLine(ts: now, "task_started", turn: "t") + "\n"
                + evLine(ts: now, "task_complete", turn: "t") + "\n")
        let store = try DiskTraceStore.inMemory()
        _ = await AgentActivitySync(configuration: .init(codexHome: home)).sync(store: store, now: now)
        let activity = try #require(
            try await store.activities(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400)).first)
        #expect(activity.workingDirectory == "/tmp/real")
        #expect(!String(describing: activity).contains(secret))
        #expect(!String(describing: activity).contains("EVIL"))
    }

    @Test("C15: malformed JSON fails closed with a typed gap, no event")
    func malformedFailsClosed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            metaLine(ts: now, sessionID: "s15", cwd: "/tmp/p") + "\n"
                + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"bad\q"}}"# + "\n"
                + evLine(ts: now, "task_complete", turn: "bad") + "\n")
        let store = try DiskTraceStore.inMemory()
        _ = await AgentActivitySync(configuration: .init(codexHome: home)).sync(store: store, now: now)
        let gaps = try await store.coverageGaps(from: now.addingTimeInterval(-86_400))
        #expect(gaps.contains { $0.cause == .malformedRecord })
    }

    @Test("C18: desktop originator is not mislabeled CLI or IDE")
    func originatorMapping() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeLog(
            home, "rollout.jsonl",
            metaLine(
                ts: now, sessionID: "s18", cwd: "/tmp/p", originator: "codex_work_desktop",
                source: "vscode", version: "0.162.0-alpha.17.2") + "\n"
                + evLine(ts: now, "task_started", turn: "t") + "\n"
                + evLine(ts: now, "task_complete", turn: "t") + "\n")
        let store = try DiskTraceStore.inMemory()
        _ = await AgentActivitySync(configuration: .init(codexHome: home)).sync(store: store, now: now)
        let window = try #require(try await store.taskWindows(activeSince: now.addingTimeInterval(-86_400)).first)
        #expect(window.clientKind == .codexDesktop)
        #expect(window.clientVersion == "0.162.0-alpha.17.2")
        #expect(window.verification == .unverified)
    }

    @Test("C16: with 401 logs no file is permanently starved")
    func fairness() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        for index in 0..<401 {
            try Data(
                (metaLine(ts: now, sessionID: "f\(index)", cwd: "/tmp/p") + "\n"
                    + evLine(ts: now, "task_started", turn: "t") + "\n"
                    + evLine(ts: now, "task_complete", turn: "t") + "\n").utf8
            ).write(to: logURL(home, "log-\(index).jsonl"))
        }
        let store = try DiskTraceStore(path: try makeHome().appending(path: "db.sqlite").path)
        let config = CodexIntegrationConfiguration(
            codexHome: home, byteBudgetPerSync: 1 << 20, perFileBudgetBytes: 4096,
            discoveryInterval: 0)
        let sync = AgentActivitySync(configuration: config)
        var t = now
        for _ in 0..<8 {
            _ = await sync.sync(store: store, now: t)
            t = t.addingTimeInterval(1)
        }
        let counts = try await store.rowCounts()
        #expect(counts["session_sync"] == 401)
    }
}
