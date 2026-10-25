import Foundation
import Testing

@testable import DiskTraceCore

@Suite("Cursor Agent transcripts")
struct CursorTranscriptTests {
    @Test("path helpers decode session and workspace")
    func pathHelpers() {
        let path =
            "/Users/me/.cursor/projects/Users-me-Projects-demo/agent-transcripts/abc-123/abc-123.jsonl"
        #expect(CursorTranscriptParser.isCursorLogPath(path))
        #expect(CursorTranscriptParser.sessionHash(fromLogPath: path) == "abc-123")
        #expect(CursorTranscriptParser.workingDirectory(fromLogPath: path) == "/Users/me/Projects/demo")
    }

    @Test("parser recognizes user turn and turn_ended without reading message bodies")
    func parseMarkers() {
        let user = Data(#"{"role":"user","message":{"content":[{"type":"text","text":"ignored"}]}}"#.utf8)
        let ended = Data(#"{"type":"turn_ended","status":"success"}"#.utf8)
        #expect(CursorTranscriptParser.parse(user).kind == .userTurn)
        #expect(CursorTranscriptParser.parse(ended).kind == .turnEnded(status: "success"))
    }

    @Test("sync ingests cursor transcripts from projects tree")
    func syncCursor() async throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "disktrace-cursor-\(UUID().uuidString)", directoryHint: .isDirectory)
        let transcript =
            home.appending(path: ".cursor/projects/Users-me-Projects-app/agent-transcripts/sess-1")
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        let log = transcript.appending(path: "sess-1.jsonl")
        let body = [
            #"{"role":"user","message":{"content":[]}}"#,
            #"{"type":"turn_ended","status":"success"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: log)

        let store = try DiskTraceStore.inMemory()
        let sync = AgentActivitySync(
            configuration: .init(
                codexHome: home.appending(path: ".codex-empty"), includeCursorProjects: true,
                cursorProjectsRoot: home.appending(path: ".cursor/projects")))
        let now = Date()
        _ = await sync.sync(store: store, now: now)

        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-3600))
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.clientKind == .cursorAgent)
        #expect(window.lifecycle == .completed)
    }
}
