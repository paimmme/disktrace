import Foundation

/// Read-only, whitelist parser for Cursor Agent JSONL transcripts.
///
/// Cursor stores sessions at
/// `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<uuid>/<uuid>.jsonl`.
/// We never decode `message` bodies or tool payloads — only structural markers
/// needed for time windows and working-directory overlap.
public enum CursorTranscriptParser {
    public struct LineEvent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case userTurn
            case turnEnded(status: String?)
            case ignored
        }

        public let kind: Kind
        public let timestamp: Date?
    }

    public static func isCursorLogPath(_ path: String) -> Bool {
        path.contains("/agent-transcripts/") && path.hasSuffix(".jsonl")
    }

    /// Stable session identity from the transcript path (directory or file uuid).
    public static func sessionHash(fromLogPath path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let transcriptsIndex = components.lastIndex(of: "agent-transcripts"),
            transcriptsIndex + 1 < components.count
        else {
            return path
        }
        let sessionComponent = components[transcriptsIndex + 1]
        if sessionComponent.hasSuffix(".jsonl") {
            return String(sessionComponent.dropLast(".jsonl".count))
        }
        return sessionComponent
    }

    /// Best-effort decode of the workspace path embedded in the projects folder name.
    public static func workingDirectory(fromLogPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let projectsIndex = components.lastIndex(of: "projects"),
            projectsIndex + 1 < components.count
        else { return nil }
        let encoded = components[projectsIndex + 1]
        guard !encoded.isEmpty else { return nil }
        let withSlashes = encoded.replacingOccurrences(of: "-", with: "/")
        if withSlashes.hasPrefix("/") { return FilePaths.canonical(withSlashes) }
        return FilePaths.canonical("/" + withSlashes)
    }

    public static func parse(_ line: Data, now: Date = Date()) -> LineEvent {
        var scanner = CodexJSONScanner(line, maxValueBytes: 256)
        guard (try? scanner.consume(0x7B)) ?? false else {
            return LineEvent(kind: .ignored, timestamp: nil)
        }
        var role: String?
        var type: String?
        var status: String?
        var timestamp: Date?
        if (try? scanner.consume(0x7D)) ?? false {
            return LineEvent(kind: .ignored, timestamp: nil)
        }
        do {
            while true {
                let key = try scanner.readString()
                guard try scanner.consume(0x3A) else { break }
                switch key {
                case "role":
                    if scanner.nextIsString() { role = try scanner.readString() }
                    else { try scanner.skipValue() }
                case "type":
                    if scanner.nextIsString() { type = try scanner.readString() }
                    else { try scanner.skipValue() }
                case "status":
                    if scanner.nextIsString() { status = try scanner.readString() }
                    else { try scanner.skipValue() }
                case "timestamp":
                    if scanner.nextIsString() {
                        timestamp = ISO8601.parse(try scanner.readString(), now: now)
                    } else { try scanner.skipValue() }
                default:
                    try scanner.skipValue()
                }
                if try scanner.consume(0x7D) { break }
                guard try scanner.consume(0x2C) else { break }
            }
        } catch {
            return LineEvent(kind: .ignored, timestamp: nil)
        }

        if type == "turn_ended" {
            return LineEvent(kind: .turnEnded(status: status), timestamp: timestamp)
        }
        if role == "user" {
            return LineEvent(kind: .userTurn, timestamp: timestamp)
        }
        return LineEvent(kind: .ignored, timestamp: timestamp)
    }
}
