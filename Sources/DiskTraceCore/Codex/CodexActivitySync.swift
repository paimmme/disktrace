import CryptoKit
import Darwin
import Foundation

public struct CodexSyncResult: Sendable, Equatable {
    public var filesScanned = 0
    public var activitiesUpserted = 0
    public var gapsRecorded = 0
    public init() {}
}

/// Incremental Codex session sync.
///
/// Unlike a start-time snapshot, this runs every monitoring cycle and reads only
/// the **appended** portion of each session log. It keeps a per-file cursor
/// (identity, byte offset) in SQLite, resets the cursor and records a
/// `CoverageGap` when a log is truncated/replaced/rotated, and upserts activity
/// rows under a stable identity so re-reading never creates duplicates. The
/// activity rows and cursors are committed in one transaction.
public actor AgentActivitySync {
    private struct Runtime {
        var readPosition: Int64 = 0
        var carry = Data()
        var sessionIDHash: String?
        var workingDirectory: String?
        var openTaskID: String?
        var openTaskStart: Date?
        var sawTaskEvent = false
        var firstAt: Date?
        var lastAt: Date?
    }

    private struct FileAttributes {
        let identity: String
        let size: Int64
        let modifiedAt: Date?
    }

    private var runtimes: [String: Runtime] = [:]
    private let configuration: CodexIntegrationConfiguration
    private let schema: CodexEventSchema

    public init(
        configuration: CodexIntegrationConfiguration = CodexIntegrationConfiguration(),
        schema: CodexEventSchema = .default
    ) {
        self.configuration = configuration
        self.schema = schema
    }

    @discardableResult
    public func sync(
        store: DiskTraceStore, now: Date, byteBudget: Int? = nil
    ) async -> CodexSyncResult {
        var result = CodexSyncResult()
        let files = sessionFiles()
        guard !files.isEmpty else { return result }

        var activities: [AgentActivity] = []
        var states: [SessionSyncState] = []
        var gaps: [CoverageGap] = []
        var remainingBudget = byteBudget ?? configuration.byteBudgetPerSync

        for file in files {
            guard remainingBudget > 0 else { break }
            let path = FilePaths.canonical(file.path)
            guard let attributes = attributes(of: path) else { continue }
            let stored = try? await store.sessionSyncState(path: path)

            var runtime = runtimes[path] ?? Runtime()
            let firstSight = runtimes[path] == nil

            if firstSight, let stored {
                runtime.readPosition = stored.byteOffset
                runtime.sessionIDHash = stored.sessionIDHash
                runtime.workingDirectory = stored.workingDirectory
                if stored.fileIdentity != attributes.identity {
                    runtime = Runtime()
                    gaps.append(rotationGap(path: path, now: now))
                }
            } else if let stored, stored.fileIdentity != attributes.identity {
                runtime = Runtime()
                gaps.append(rotationGap(path: path, now: now))
            } else if attributes.size < runtime.readPosition {
                runtime = Runtime()
                gaps.append(rotationGap(path: path, now: now))
            }

            // Nothing appended and no reset: skip the read entirely.
            if let stored, runtime.readPosition > 0,
                stored.fileSize == attributes.size,
                stored.fileIdentity == attributes.identity
            {
                if runtime.sessionIDHash == nil { runtime.sessionIDHash = stored.sessionIDHash }
                if runtime.workingDirectory == nil { runtime.workingDirectory = stored.workingDirectory }
                runtimes[path] = runtime
                continue
            }

            var produced: [AgentActivity] = []
            let budget = min(remainingBudget, configuration.byteBudgetPerSync)
            guard
                let chunk = try? CodexSessionLog.read(
                    file: URL(filePath: path), from: runtime.readPosition, carry: runtime.carry,
                    budget: budget, maxRecordBytes: configuration.maxRecordBytes)
            else { continue }

            for line in chunk.lines {
                if let closed = ingest(line: line, into: &runtime) { produced.append(closed) }
            }
            runtime.readPosition = chunk.readPosition
            runtime.carry = chunk.carry
            remainingBudget -= max(0, chunk.bytesRead)
            if chunk.skippedOversized > 0 {
                gaps.append(
                    CoverageGap(
                        start: now, cause: .oversizedRecord, affectedRoots: [path],
                        severity: .low))
            }

            produced.append(contentsOf: currentActivities(runtime: runtime, path: path))
            runtimes[path] = runtime
            activities.append(contentsOf: produced)
            states.append(
                SessionSyncState(
                    filePath: path, fileIdentity: attributes.identity,
                    sessionIDHash: runtime.sessionIDHash, byteOffset: runtime.readPosition,
                    fileSize: attributes.size, modifiedAt: attributes.modifiedAt,
                    lastProcessed: now, workingDirectory: runtime.workingDirectory))
            result.filesScanned += 1
        }

        // Deduplicate by deterministic id: an open task and its closure share an
        // id, and the closed (bounded) form must win.
        var byID: [UUID: AgentActivity] = [:]
        for activity in activities { byID[activity.id] = activity }
        let unique = Array(byID.values)

        do {
            try await store.applySync(activities: unique, states: states, gaps: gaps)
        } catch {
            return result
        }
        result.activitiesUpserted = unique.count
        result.gapsRecorded = gaps.count
        return result
    }

    // MARK: - Event ingestion

    private func ingest(line: Data, into runtime: inout Runtime) -> AgentActivity? {
        guard let event = CodexEventParser.parse(line, schema: schema) else { return nil }
        if let timestamp = event.timestamp {
            if runtime.firstAt == nil { runtime.firstAt = timestamp }
            runtime.lastAt = timestamp
        }
        if let sessionID = event.sessionID, runtime.sessionIDHash == nil {
            runtime.sessionIDHash = Self.hash(sessionID)
        }
        if let cwd = event.workingDirectory {
            runtime.workingDirectory = configuration.hashWorkingDirectory
                ? Self.hash(cwd) : Self.normalize(cwd)
        }
        guard let type = event.type else { return nil }

        if schema.isTaskStart(type) {
            runtime.sawTaskEvent = true
            runtime.openTaskID =
                event.taskID
                ?? "task-\(Int((event.timestamp ?? runtime.lastAt ?? Date()).timeIntervalSince1970))"
            runtime.openTaskStart = event.timestamp ?? runtime.lastAt
            return nil
        }

        if schema.isTaskEnd(type) {
            runtime.sawTaskEvent = true
            if let taskKey = runtime.openTaskID {
                let activity = makeActivity(
                    runtime: runtime, taskKey: taskKey, start: runtime.openTaskStart,
                    end: event.timestamp, bounded: true)
                runtime.openTaskID = nil
                runtime.openTaskStart = nil
                return activity
            }
            if let taskKey = event.taskID {
                return makeActivity(
                    runtime: runtime, taskKey: taskKey,
                    start: runtime.firstAt ?? event.timestamp, end: event.timestamp, bounded: true)
            }
            return nil
        }
        return nil
    }

    private func currentActivities(runtime: Runtime, path: String) -> [AgentActivity] {
        let session = runtime.sessionIDHash ?? Self.hash(path)
        if let taskKey = runtime.openTaskID {
            // Still open: expose it now, flagged lower confidence.
            return [
                AgentActivity(
                    sessionIDHash: session, client: .codexCLI,
                    startedAt: runtime.openTaskStart ?? runtime.firstAt ?? Date(),
                    endedAt: nil, workingDirectory: runtime.workingDirectory,
                    taskIDHash: Self.hash(taskKey), windowIsTaskBounded: false)
            ]
        }
        if !runtime.sawTaskEvent, let first = runtime.firstAt {
            return [
                AgentActivity(
                    sessionIDHash: session, client: .codexCLI, startedAt: first,
                    endedAt: runtime.lastAt, workingDirectory: runtime.workingDirectory,
                    taskIDHash: nil, windowIsTaskBounded: false)
            ]
        }
        return []
    }

    private func makeActivity(
        runtime: Runtime, taskKey: String, start: Date?, end: Date?, bounded: Bool
    ) -> AgentActivity {
        let session = runtime.sessionIDHash ?? Self.hash("session")
        return AgentActivity(
            sessionIDHash: session, client: .codexCLI,
            startedAt: start ?? runtime.firstAt ?? Date(), endedAt: end,
            workingDirectory: runtime.workingDirectory, taskIDHash: Self.hash(taskKey),
            windowIsTaskBounded: bounded)
    }

    // MARK: - Filesystem

    private func sessionFiles() -> [URL] {
        let fileManager = FileManager.default
        let directory = configuration.sessionsDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.1 < $1.1 }
        return files.prefix(configuration.maxFilesPerSync).map(\.0)
    }

    private func attributes(of path: String) -> FileAttributes? {
        var fileStat = stat()
        guard lstat(path, &fileStat) == 0 else { return nil }
        let identity = "\(fileStat.st_dev):\(fileStat.st_ino)"
        let mtime = Date(
            timeIntervalSince1970: TimeInterval(fileStat.st_mtimespec.tv_sec)
                + TimeInterval(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileAttributes(
            identity: identity, size: Int64(fileStat.st_size), modifiedAt: mtime)
    }

    private func rotationGap(path: String, now: Date) -> CoverageGap {
        CoverageGap(
            start: now, cause: .logRotation, affectedRoots: [path], severity: .medium)
    }

    // MARK: - Helpers

    private static func normalize(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
