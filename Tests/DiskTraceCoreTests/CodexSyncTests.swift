import Foundation
import Testing

@testable import DiskTraceCore

private func tempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-codex-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func writeSessionLog(_ home: URL, name: String, lines: [String]) throws -> URL {
    let dir = home.appending(path: "sessions/2026/10/13", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: name)
    let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    try Data(text.utf8).write(to: url)
    return url
}

private func appendToLog(_ url: URL, _ line: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
}

@Suite("Codex log privacy & streaming")
struct CodexSyncTests {
    @Test("extracts only whitelisted metadata; ignores decoy cwd/session inside content")
    func privacyStructural() async throws {
        let home = try tempDirectory("privacy")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let start = iso(now)
        let end = iso(now.addingTimeInterval(15))
        let decoy = #"{\"cwd\":\"/evil\",\"session_id\":\"EVIL\",\"id\":\"EVIL2\"}"#
        _ = try writeSessionLog(home, name: "rollout.jsonl", lines: [
            #"{"type":"session_meta","timestamp":"\#(start)","payload":{"session_id":"abc123","cwd":"/Users/dev/proj","text":"\#(decoy)","command":"id --cwd=/evil --session_id EVIL3"}}"#,
            #"{"type":"task_started","timestamp":"\#(start)","payload":{"task_id":"t1"}}"#,
            #"{"type":"message","timestamp":"\#(start)","payload":{"cwd":"/evil2","session_id":"EVIL4"}}"#,
            #"{"type":"task_completed","timestamp":"\#(end)","payload":{"task_id":"t1"}}"#,
        ])

        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(
            configuration: CodexIntegrationConfiguration(codexHome: home))
        _ = await sync.sync(store: store, now: now)

        let activities = try await store.activities(
            from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(3_600))
        #expect(activities.count == 1)
        let activity = try #require(activities.first)
        #expect(activity.workingDirectory == "/Users/dev/proj")
        #expect(activity.windowIsTaskBounded)
        #expect(!activity.sessionIDHash.contains("abc123"))
        #expect(activity.sessionIDHash.count == 64)
        let serialized = String(describing: activity)
        #expect(!serialized.contains("EVIL"))
        #expect(!serialized.contains("/evil"))
    }

    @Test("re-syncing an unchanged log creates no duplicate activity")
    func idempotentResync() async throws {
        let home = try tempDirectory("idempotent")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeSessionLog(home, name: "rollout.jsonl", lines: [
            #"{"type":"session_meta","timestamp":"\#(iso(now))","payload":{"session_id":"s1","cwd":"/p"}}"#,
            #"{"type":"task_started","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
            #"{"type":"task_completed","timestamp":"\#(iso(now.addingTimeInterval(5)))","payload":{"task_id":"t1"}}"#,
        ])
        let store = try DiskTraceStore(path: try tempDirectory("db").appending(path: "db.sqlite").path)
        let sync = AgentActivitySync(configuration: CodexIntegrationConfiguration(codexHome: home))
        _ = await sync.sync(store: store, now: now)
        _ = await sync.sync(store: store, now: now.addingTimeInterval(1))
        _ = await sync.sync(store: store, now: now.addingTimeInterval(2))
        let counts = try await store.rowCounts()
        #expect(counts["agent_activities"] == 1)
        #expect(counts["session_sync"] == 1)
    }

    @Test("only appended bytes are read; a new task adds exactly one activity")
    func incrementalAppend() async throws {
        let home = try tempDirectory("append")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let log = try writeSessionLog(home, name: "rollout.jsonl", lines: [
            #"{"type":"session_meta","timestamp":"\#(iso(now))","payload":{"session_id":"s1","cwd":"/p"}}"#,
            #"{"type":"task_started","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
            #"{"type":"task_completed","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
        ])
        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(configuration: CodexIntegrationConfiguration(codexHome: home))
        _ = await sync.sync(store: store, now: now)
        let firstState = try await store.sessionSyncState(path: FilePaths.canonical(log.path))
        let firstOffset = try #require(firstState?.byteOffset)

        try appendToLog(log, #"{"type":"task_started","timestamp":"\#(iso(now.addingTimeInterval(60)))","payload":{"task_id":"t2"}}"#)
        try appendToLog(log, #"{"type":"task_completed","timestamp":"\#(iso(now.addingTimeInterval(70)))","payload":{"task_id":"t2"}}"#)
        _ = await sync.sync(store: store, now: now.addingTimeInterval(80))

        let second = try await store.sessionSyncState(path: FilePaths.canonical(log.path))
        #expect((second?.byteOffset ?? 0) > firstOffset)
        let counts = try await store.rowCounts()
        #expect(counts["agent_activities"] == 2)
    }

    @Test("truncation resets the cursor and records a coverage gap")
    func truncationResets() async throws {
        let home = try tempDirectory("truncate")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let log = try writeSessionLog(home, name: "rollout.jsonl", lines: [
            #"{"type":"session_meta","timestamp":"\#(iso(now))","payload":{"session_id":"s1","cwd":"/p"}}"#,
            #"{"type":"task_started","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
            #"{"type":"task_completed","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
        ])
        let store = try DiskTraceStore(path: try tempDirectory("db").appending(path: "db.sqlite").path)
        let sync = AgentActivitySync(configuration: CodexIntegrationConfiguration(codexHome: home))
        _ = await sync.sync(store: store, now: now)

        // Truncate in place to a shorter file (same inode).
        try Data(#"{"type":"session_meta","payload":{"session_id":"s1","cwd":"/p"}}"#.utf8).write(to: log)
        _ = await sync.sync(store: store, now: now.addingTimeInterval(5))

        let gaps = try await store.coverageGaps(from: now.addingTimeInterval(-3_600))
        #expect(gaps.contains { $0.cause == .logRotation })
    }

    @Test("an oversized single record is skipped and recorded, later records still parse")
    func oversizedRecordSkipped() async throws {
        let home = try tempDirectory("oversize")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let dir = home.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appending(path: "rollout.jsonl")
        // One long line with no trailing newline, exceeding the record cap.
        try Data(String(repeating: "x", count: 4_000).utf8).write(to: log)

        let store = try DiskTraceStore.inMemory()
        let config = CodexIntegrationConfiguration(
            codexHome: home, byteBudgetPerSync: 1 << 20, maxRecordBytes: 512)
        let sync = AgentActivitySync(configuration: config)
        _ = await sync.sync(store: store, now: now)

        let gaps = try await store.coverageGaps(from: now.addingTimeInterval(-3_600))
        #expect(gaps.contains { $0.cause == .oversizedRecord })
    }

    @Test("parser handles escapes, unicode and nesting without reading bodies")
    func parserRobustness() throws {
        let line = Data(
            #"{"type":"session_meta","timestamp":"2026-10-12T10:00:00Z","payload":{"session_id":"n\u00e9\u0041","cwd":"/Users/d\u00e9v","nested":{"cwd":"/SHOULD-NOT-READ"}}}"#
                .utf8)
        let event = try #require(try? CodexEventParser.parse(line, schema: .default).get())
        #expect(event.sessionID == "néA")
        #expect(event.workingDirectory == "/Users/dév")
        #expect(event.topType == "session_meta")

        // A skipped (unknown-value) container must not leak a nested key, and an
        // unknown top-level event must not even decode its payload.
        let noisy = Data(
            #"{"type":"message","payload":{"cwd":"/leak","deep":{"session_id":"LEAK"}}}"#.utf8)
        let counter = CodexDecodeCounter()
        let noisyEvent = try #require(
            try? CodexEventParser.parse(noisy, schema: .default, counter: counter).get())
        #expect(noisyEvent.workingDirectory == nil)
        #expect(noisyEvent.sessionID == nil)
        // Only the two top-level keys and the "type" value are decoded; the
        // payload body is skipped and does not scale the count.
        #expect(counter.decodedStrings == 3)
    }

    @Test("hashed working directory option")
    func hashWorkingDirectory() async throws {
        let home = try tempDirectory("hash")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        _ = try writeSessionLog(home, name: "rollout.jsonl", lines: [
            #"{"type":"session_meta","timestamp":"\#(iso(now))","payload":{"session_id":"s1","cwd":"/Users/dev/p"}}"#,
            #"{"type":"task_started","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
            #"{"type":"task_completed","timestamp":"\#(iso(now))","payload":{"task_id":"t1"}}"#,
        ])
        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(
            configuration: CodexIntegrationConfiguration(
                codexHome: home, hashWorkingDirectory: true))
        _ = await sync.sync(store: store, now: now)
        let activity = try #require(
            try await store.activities(
                from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(3_600)).first)
        #expect(activity.workingDirectory?.count == 64)
    }
}
