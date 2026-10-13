import CryptoKit
import Foundation

/// Read-only Codex session metadata reader.
///
/// Privacy is structural, not just policy: this reader never fully parses the
/// prompt/command/message payloads. It scans each log line for a **whitelist**
/// of keys only — session id, working directory and timestamps — and discards
/// everything else. No prompt, command, message, source or file content is ever
/// materialized into a value it stores.
public struct CodexSessionReader: Sendable {
    public struct Configuration: Sendable {
        public var codexHome: URL
        /// Replace the working directory with a hash before it leaves the reader.
        public var hashWorkingDirectory: Bool
        /// Upper bound on files inspected per pass (keeps I/O bounded).
        public var maxFiles: Int

        public init(
            codexHome: URL? = nil,
            hashWorkingDirectory: Bool = false,
            maxFiles: Int = 200
        ) {
            self.codexHome =
                codexHome
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".codex", directoryHint: .isDirectory)
            self.hashWorkingDirectory = hashWorkingDirectory
            self.maxFiles = maxFiles
        }
    }

    private let configuration: Configuration
    private static let allowedKeys = ["session_id", "id", "cwd", "working_directory", "timestamp"]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns activities for sessions with log activity at or after `since`.
    public func recentActivities(since: Date) async throws -> [AgentActivity] {
        try await Task.detached(priority: .utility) {
            try Self.scan(configuration: configuration, since: since)
        }.value
    }

    static func scan(configuration: Configuration, since: Date) throws -> [AgentActivity] {
        let fileManager = FileManager.default
        let sessionsRoot = configuration.codexHome.appending(
            path: "sessions", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return [] }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        else {
            return []
        }

        var activities: [AgentActivity] = []
        var inspected = 0
        for case let url as URL in enumerator {
            guard inspected < configuration.maxFiles else { break }
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if let modified = values?.contentModificationDate, modified < since { continue }
            inspected += 1
            if let activity = parse(file: url, configuration: configuration, since: since) {
                activities.append(activity)
            }
        }
        return activities
    }

    private static func parse(
        file: URL, configuration: Configuration, since: Date
    ) -> AgentActivity? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // Bounded read: session metadata is near the start of the log.
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        var sessionID: String?
        var cwd: String?
        var earliest: Date?
        var latest: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if sessionID == nil {
                sessionID =
                    Self.value(for: "session_id", in: line)
                    ?? Self.value(for: "id", in: line)
            }
            if cwd == nil {
                cwd =
                    Self.value(for: "cwd", in: line)
                    ?? Self.value(for: "working_directory", in: line)
            }
            if let stamp = Self.value(for: "timestamp", in: line),
                let date = Self.parseDate(stamp)
            {
                if earliest == nil || date < earliest! { earliest = date }
                if latest == nil || date > latest! { latest = date }
            }
        }

        let resolvedID = sessionID ?? file.deletingPathExtension().lastPathComponent
        guard let windowStart = earliest ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        guard (latest ?? windowStart) >= since else { return nil }

        let workingDirectory: String?
        if let cwd {
            workingDirectory = configuration.hashWorkingDirectory ? Self.hash(cwd) : normalize(cwd)
        } else {
            workingDirectory = nil
        }

        return AgentActivity(
            sessionIDHash: Self.hash(resolvedID),
            client: .codexCLI,
            startedAt: windowStart,
            endedAt: latest,
            workingDirectory: workingDirectory)
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// Extracts the string value for a whitelisted key from a single line,
    /// without deserializing the surrounding JSON (and therefore without
    /// touching prompt/command payloads).
    static func value(for key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < line.endIndex,
            line[index] == " " || line[index] == ":" || line[index] == "\t"
        {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "\"" else { return nil }
        index = line.index(after: index)
        var value = ""
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                index = line.index(after: index)
                if index < line.endIndex {
                    value.append(line[index])
                    index = line.index(after: index)
                }
                continue
            }
            if character == "\"" { break }
            value.append(character)
            index = line.index(after: index)
        }
        return value
    }
}
