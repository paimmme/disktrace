import Foundation
import Testing

@testable import DiskTraceCore

private func tempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktrace-codex-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Codex metadata reader (privacy)")
struct CodexReaderTests {
    @Test("extracts only whitelisted metadata and never content")
    func extractsMetadataOnly() async throws {
        let home = try tempDirectory("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionDir = home.appending(
            path: "sessions/2026/10/13", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let secret = "SUPER-SECRET-PROMPT-DO-NOT-STORE"
        let log = """
            {"timestamp":"2026-10-12T10:00:00.000Z","type":"session","payload":{"session_id":"abc123","cwd":"/Users/dev/secretproj","text":"\(secret)","command":"rm -rf /"}}
            {"timestamp":"2026-10-12T11:30:00.000Z","type":"turn","payload":{"message":"\(secret)"}}
            """
        try Data(log.utf8).write(to: sessionDir.appending(path: "rollout-x.jsonl"))

        let reader = CodexSessionReader(
            configuration: .init(codexHome: home, hashWorkingDirectory: false))
        let activities = try await reader.recentActivities(
            since: Date(timeIntervalSince1970: 0))

        #expect(activities.count == 1)
        let activity = try #require(activities.first)
        #expect(activity.sessionIDHash != "abc123")
        #expect(activity.sessionIDHash.count == 64)  // sha256 hex
        #expect(activity.workingDirectory == "/Users/dev/secretproj")
        #expect(activity.client == .codexCLI)
        #expect(activity.startedAt == ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")
            || activity.startedAt.timeIntervalSince1970 == 1_791_780_000)
        // The secret must not appear anywhere in the produced value.
        #expect(!activity.sessionIDHash.contains(secret))
        #expect(activity.workingDirectory?.contains(secret) != true)
    }

    @Test("can hash the working directory for stricter privacy")
    func hashesWorkingDirectory() async throws {
        let home = try tempDirectory("hashhome")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionDir = home.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let log =
            #"{"timestamp":"2026-10-12T10:00:00Z","payload":{"session_id":"s1","cwd":"/Users/dev/p"}}"#
        try Data(log.utf8).write(to: sessionDir.appending(path: "rollout-y.jsonl"))

        let reader = CodexSessionReader(
            configuration: .init(codexHome: home, hashWorkingDirectory: true))
        let activities = try await reader.recentActivities(since: Date(timeIntervalSince1970: 0))
        let activity = try #require(activities.first)
        #expect(activity.workingDirectory?.count == 64)
        #expect(activity.workingDirectory?.contains("/Users") != true)
    }

    @Test("missing codex home yields no activities")
    func missingHomeIsEmpty() async throws {
        let reader = CodexSessionReader(
            configuration: .init(codexHome: URL(filePath: "/nonexistent-\(UUID().uuidString)")))
        let activities = try await reader.recentActivities(since: Date(timeIntervalSince1970: 0))
        #expect(activities.isEmpty)
    }

    @Test("whitelist value extractor reads only the requested key")
    func valueExtractor() {
        let line = #"{"cwd":"/a/b","text":"ignored","timestamp":"2026-01-01T00:00:00Z"}"#
        #expect(CodexSessionReader.value(for: "cwd", in: line) == "/a/b")
        #expect(CodexSessionReader.value(for: "timestamp", in: line) == "2026-01-01T00:00:00Z")
        #expect(CodexSessionReader.value(for: "absent", in: line) == nil)
    }
}
