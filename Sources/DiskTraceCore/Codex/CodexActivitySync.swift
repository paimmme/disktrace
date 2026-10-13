import CryptoKit
import Darwin
import Foundation

public struct CodexSyncResult: Sendable, Equatable {
    public var filesScanned = 0
    public var activitiesUpserted = 0
    public var taskWindowsUpserted = 0
    public var gapsRecorded = 0
    public var bytesRead = 0
    public init() {}
}

/// Incremental Codex session sync.
///
/// Runs every cycle and reads only the **appended** portion of each session log.
/// It keeps two positions per file: an in-memory `readPosition` and a durable
/// **committed** offset that is always a complete-line boundary (or an
/// intentionally dropped oversized record). Activities, task windows and cursors
/// commit in one transaction. Activity ids are stable, so re-reading a line
/// upserts rather than duplicates. Open tasks survive a restart by being
/// recovered from `task_windows`.
public actor AgentActivitySync {
    private struct OpenTask {
        var startedAt: Date?
        var startOffset: Int64
        var lifecycle: TaskLifecycleState
        var createdAt: Date
    }

    private struct Runtime {
        var readPosition: Int64
        var carry: Data
        var carryStart: Int64
        var committedOffset: Int64
        var sessionHash: String?
        var clientKind: AgentClientKind = .unknown
        var clientVersion: String?
        var cwd: String?
        var schemaKind = "codex-envelope"
        var verification: VerificationState = .unverified
        var sessionIDConflict = false
        var discardingOversized = false
        var openTasks: [String: OpenTask] = [:]
        var firstEventAt: Date?
        var lastEventAt: Date?
        var lastError: String?
        var needsRotationGap: Bool = false
    }

    private struct Discovered {
        let url: URL
        let path: String
        let modifiedAt: Date
    }

    private let configuration: CodexIntegrationConfiguration
    private let schema: CodexEventSchema
    private var runtimes: [String: Runtime] = [:]
    private var servedAt: [String: Date] = [:]
    private var discovered: [Discovered] = []
    private var lastDiscovery: Date?

    public init(
        configuration: CodexIntegrationConfiguration = CodexIntegrationConfiguration(),
        schema: CodexEventSchema = CodexEventSchema(acceptLegacyTopLevel: true)
    ) {
        self.configuration = configuration
        self.schema = schema
    }

    @discardableResult
    public func sync(
        store: DiskTraceStore, now: Date, byteBudget: Int? = nil
    ) async -> CodexSyncResult {
        var result = CodexSyncResult()
        refreshDiscovery(now: now)
        guard !discovered.isEmpty else { return result }

        // Fair scheduling: least-recently-served first (persisted per file).
        let ordered = discovered.sorted {
            let l = servedAt[$0.path] ?? .distantPast
            let r = servedAt[$1.path] ?? .distantPast
            if l != r { return l < r }
            return $0.path < $1.path
        }

        var remaining = byteBudget ?? configuration.byteBudgetPerSync
        var activities: [AgentActivity] = []
        var taskWindows: [TaskWindow] = []
        var states: [SessionSyncState] = []
        var gaps: [CoverageGap] = []
        var served = 0

        for item in ordered {
            if remaining < configuration.perFileBudgetBytes / 4 { break }
            if served >= configuration.maxFilesPerSync { break }
            guard let attributes = attributes(of: item.path) else { continue }

            var runtime = await loadRuntime(
                path: item.path, identity: attributes.identity, size: attributes.size,
                modifiedAt: attributes.modifiedAt, store: store, now: now)

            if runtime.needsRotationGap {
                gaps.append(
                    CoverageGap(
                        start: now, cause: .logRotation, affectedRoots: [item.path],
                        severity: .medium))
                runtime.needsRotationGap = false
            }

            // Skip only when truly nothing to do: read to EOF, no partial line,
            // identity and mtime unchanged.
            if runtime.readPosition >= attributes.size, runtime.carry.isEmpty {
                let stored = try? await store.sessionSyncState(path: item.path)
                if let stored, stored.fileIdentity == attributes.identity,
                    stored.modifiedAt == attributes.modifiedAt
                {
                    runtimes[item.path] = runtime
                    continue
                }
            }

            let budget = min(remaining, configuration.perFileBudgetBytes)
            guard
                let chunk = try? CodexSessionLog.read(
                    file: item.url, readPosition: runtime.readPosition, carry: runtime.carry,
                    carryStart: runtime.carryStart, budget: budget,
                    maxRecordBytes: configuration.maxRecordBytes)
            else { continue }

            remaining -= max(0, chunk.bytesRead)
            result.bytesRead += max(0, chunk.bytesRead)
            served += 1
            servedAt[item.path] = now

            var produced: [AgentActivity] = []
            var windows: [TaskWindow] = []
            if chunk.oversizedPartial, !runtime.discardingOversized {
                runtime.discardingOversized = true
                gaps.append(oversizedGap(path: item.path, now: now))
            }
            for _ in 0..<chunk.oversizedComplete {
                gaps.append(oversizedGap(path: item.path, now: now))
            }
            if runtime.discardingOversized, !chunk.oversizedPartial {
                // The oversized record has now been consumed (a newline appeared).
                runtime.discardingOversized = false
            }

            for line in chunk.lines {
                let (acts, wins, lineGaps) = ingest(
                    line: line.data, startOffset: line.startOffset,
                    endOffset: line.endOffset, into: &runtime, path: item.path, now: now)
                produced.append(contentsOf: acts)
                windows.append(contentsOf: wins)
                gaps.append(contentsOf: lineGaps)
            }

            runtime.readPosition = chunk.readPosition
            runtime.carry = chunk.carry
            runtime.carryStart = chunk.carryStart
            runtime.committedOffset = chunk.committedOffset
            runtimes[item.path] = runtime
            result.filesScanned += 1

            activities.append(contentsOf: produced)
            taskWindows.append(contentsOf: windows)
            states.append(
                state(from: runtime, path: item.path, attributes: attributes, now: now))
        }

        // Bound the batch and dedupe by id (closed/bounded wins over running).
        var byID: [UUID: AgentActivity] = [:]
        for activity in activities { byID[activity.id] = activity }
        var windowByID: [UUID: TaskWindow] = [:]
        for window in taskWindows { windowByID[window.activityID] = window }

        do {
            try await store.applySessionBatch(
                activities: Array(byID.values), taskWindows: Array(windowByID.values),
                states: states, gaps: gaps)
        } catch {
            return result
        }
        result.activitiesUpserted = byID.count
        result.taskWindowsUpserted = windowByID.count
        result.gapsRecorded = gaps.count
        return result
    }

    // MARK: - Runtime loading / recovery

    private func loadRuntime(
        path: String, identity: String, size: Int64, modifiedAt: Date?,
        store: DiskTraceStore, now: Date
    ) async -> Runtime {
        if var existing = runtimes[path] {
            // Detect truncation between cycles.
            if existing.readPosition > size {
                let sessionHash = existing.sessionHash
                let cwd = existing.cwd
                existing = Runtime(
                    readPosition: 0, carry: Data(), carryStart: 0, committedOffset: 0)
                existing.sessionHash = sessionHash
                existing.cwd = cwd
                existing.needsRotationGap = true
            }
            return existing
        }
        guard let stored = try? await store.sessionSyncState(path: path) else {
            return Runtime(readPosition: 0, carry: Data(), carryStart: 0, committedOffset: 0)
        }
        if stored.fileIdentity != identity || size < stored.byteOffset {
            // Rotation or truncation: restart from 0; open tasks are interrupted.
            await interruptOpenTasks(
                sessionHash: stored.sessionIDHash, store: store, now: now)
            var fresh = Runtime(readPosition: 0, carry: Data(), carryStart: 0, committedOffset: 0)
            fresh.sessionHash = stored.sessionIDHash
            fresh.cwd = stored.workingDirectory
            fresh.needsRotationGap = true
            return fresh
        }
        var runtime = Runtime(
            readPosition: stored.byteOffset, carry: Data(), carryStart: stored.byteOffset,
            committedOffset: stored.byteOffset)
        runtime.sessionHash = stored.sessionIDHash
        runtime.cwd = stored.workingDirectory
        runtime.discardingOversized = stored.discardingOversized
        runtime.firstEventAt = stored.firstEventAt
        runtime.lastEventAt = stored.lastEventAt
        runtime.lastError = stored.lastError

        // Repair a legacy cursor: its offset was not proven to be a line boundary.
        if stored.cursorVersion == 0 {
            let repaired = repairLegacyCursor(
                file: URL(filePath: path), from: stored.byteOffset)
            runtime.readPosition = repaired
            runtime.carryStart = repaired
            runtime.committedOffset = repaired
            runtime.schemaKind = "legacy-repaired"
        }

        // Recover client identity from an existing task window (session metadata
        // in the prefix is not re-read).
        if let sessionHash = stored.sessionIDHash,
            let window = try? await store.latestTaskWindow(sessionHash: sessionHash)
        {
            runtime.clientKind = window.clientKind
            runtime.clientVersion = window.clientVersion
            runtime.schemaKind = window.schemaKind
            runtime.verification = window.verification
        }
        // Recover open running tasks so a later end keeps the original start.
        if let sessionHash = stored.sessionIDHash,
            let open = try? await store.openTaskWindows(sessionHash: sessionHash)
        {
            for window in open where window.sourceLogPath == path {
                runtime.openTasks[window.taskHash] = OpenTask(
                    startedAt: window.startKnown ? window.lastEventAt : nil,
                    startOffset: window.eventStartOffset ?? 0, lifecycle: .running,
                    createdAt: now)
            }
        }
        return runtime
    }

    private func repairLegacyCursor(file: URL, from offset: Int64) -> Int64 {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        let window: Int64 = min(offset, 512 * 1024)
        let start = offset - window
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
            let data = try? handle.read(upToCount: Int(window))
        else { return 0 }
        // Find the last newline; the boundary is the byte after it.
        if let lastNewline = data.lastIndex(of: 0x0A) {
            return start + Int64(data.distance(from: data.startIndex, to: lastNewline)) + 1
        }
        return 0
    }

    private func interruptOpenTasks(sessionHash: String?, store: DiskTraceStore, now: Date) async {
        guard let sessionHash else { return }
        guard let open = try? await store.openTaskWindows(sessionHash: sessionHash) else { return }
        for window in open {
            let interrupted = TaskWindow(
                activityID: window.activityID, sessionHash: window.sessionHash,
                taskHash: window.taskHash, clientKind: window.clientKind,
                clientVersion: window.clientVersion, lifecycle: .interrupted,
                startKnown: window.startKnown, endKnown: false, lastEventAt: window.lastEventAt,
                schemaKind: window.schemaKind, verification: window.verification,
                sourceLogPath: window.sourceLogPath, eventStartOffset: window.eventStartOffset,
                eventEndOffset: nil)
            try? await store.upsertTaskWindow(interrupted)
        }
    }

    // MARK: - Event ingestion

    private func ingest(
        line: Data, startOffset: Int64, endOffset: Int64, into runtime: inout Runtime,
        path: String, now: Date
    ) -> ([AgentActivity], [TaskWindow], [CoverageGap]) {
        var gaps: [CoverageGap] = []
        let parsed = CodexEventParser.parse(line, schema: schema)
        let event: CodexLogEvent
        switch parsed {
        case .success(let value):
            event = value
        case .failure(let error):
            runtime.lastError = String(describing: error)
            return (
                [], [],
                [CoverageGap(start: now, cause: .malformedRecord, affectedRoots: [path], severity: .low)]
            )
        }
        if let ts = event.timestamp {
            if runtime.firstEventAt == nil { runtime.firstEventAt = ts }
            runtime.lastEventAt = ts
        }

        if let topType = event.topType, schema.sessionMetaTopTypes.contains(topType) {
            runtime.schemaKind = event.isLegacy ? "legacyFixture" : "codex-envelope"
            if event.sessionIDConflict {
                runtime.sessionIDConflict = true
                runtime.sessionHash = nil
                gaps.append(
                    CoverageGap(
                        start: now, cause: .schemaConflict,
                        affectedRoots: [path], severity: .medium))
                return ([], [], gaps)
            }
            if let sessionID = event.sessionID { runtime.sessionHash = Self.hash(sessionID) }
            if let cwd = event.workingDirectory {
                runtime.cwd = configuration.hashWorkingDirectory ? Self.hash(cwd) : Self.normalize(cwd)
            }
            runtime.clientKind = Self.mapClient(event.originator)
            runtime.clientVersion = event.cliVersion
            runtime.verification = event.isLegacy ? .legacyUnverified : .unverified
            return ([], [], gaps)
        }

        // Resolve the lifecycle event type (envelope payload type, or legacy top type).
        let eventType = event.eventType
        guard let eventType else { return ([], [], gaps) }
        guard runtime.sessionIDConflict == false else { return ([], [], gaps) }

        let isStart = schema.taskStartedEventTypes.contains(eventType)
            || (schema.acceptLegacyTopLevel && schema.legacyTopLevelStart.contains(eventType))
        let isComplete = schema.taskCompleteEventTypes.contains(eventType)
            || (schema.acceptLegacyTopLevel && schema.legacyTopLevelEnd.contains(eventType))
        let isAbort = schema.taskAbortedEventTypes.contains(eventType)
        guard isStart || isComplete || isAbort else { return ([], [], gaps) }

        if event.missingTaskID || event.taskID == nil {
            gaps.append(
                CoverageGap(
                    start: now, cause: .schemaMissingTaskID, affectedRoots: [path],
                    severity: .low))
            return ([], [], gaps)
        }
        let taskID = event.taskID!
        let taskHash = Self.hash(taskID)
        let session = runtime.sessionHash ?? Self.hash(path)
        let schemaKind = runtime.schemaKind

        if isStart {
            if let open = runtime.openTasks[taskHash], open.lifecycle == .running {
                return ([], [], gaps)  // idempotent duplicate start
            }
            if runtime.openTasks.count >= 128 {
                gaps.append(
                    CoverageGap(
                        start: now, cause: .eventIDUnavailable, affectedRoots: [path],
                        severity: .medium))
                return ([], [], gaps)
            }
            let start = event.timestamp
            runtime.openTasks[taskHash] = OpenTask(
                startedAt: start, startOffset: startOffset, lifecycle: .running, createdAt: now)
            let activity = makeActivity(
                session: session, client: runtime.clientKind, cwd: runtime.cwd,
                taskHash: taskHash, start: start, end: nil, bounded: false)
            let window = makeWindow(
                activity: activity, session: session, clientVersion: runtime.clientVersion,
                taskHash: taskHash, lifecycle: .running,
                startKnown: start != nil, endKnown: false, lastEventAt: event.timestamp ?? now,
                schemaKind: schemaKind, verification: runtime.verification, path: path,
                startOffset: startOffset, endOffset: nil)
            return ([activity], [window], gaps)
        }

        // End (complete or abort).
        let lifecycle: TaskLifecycleState = isAbort ? .aborted : .completed
        if let open = runtime.openTasks.removeValue(forKey: taskHash) {
            let start = open.startedAt
            let bounded = (start != nil && event.timestamp != nil && event.timestamp! >= start!)
            let activity = makeActivity(
                session: session, client: runtime.clientKind, cwd: runtime.cwd,
                taskHash: taskHash, start: start, end: event.timestamp, bounded: bounded)
            let window = makeWindow(
                activity: activity, session: session, clientVersion: runtime.clientVersion,
                taskHash: taskHash, lifecycle: lifecycle,
                startKnown: start != nil, endKnown: true, lastEventAt: event.timestamp ?? now,
                schemaKind: schemaKind, verification: runtime.verification, path: path,
                startOffset: open.startOffset, endOffset: endOffset)
            return ([activity], [window], gaps)
        }
        // End without a known start.
        let activity = makeActivity(
            session: session, client: runtime.clientKind, cwd: runtime.cwd,
            taskHash: taskHash, start: event.timestamp, end: event.timestamp, bounded: false)
        let window = makeWindow(
            activity: activity, session: session, clientVersion: runtime.clientVersion,
            taskHash: taskHash, lifecycle: .unknownStart,
            startKnown: false, endKnown: true, lastEventAt: event.timestamp ?? now,
            schemaKind: schemaKind, verification: runtime.verification, path: path,
            startOffset: nil, endOffset: endOffset)
        return ([activity], [window], gaps)
    }

    private func makeActivity(
        session: String, client: AgentClientKind, cwd: String?, taskHash: String,
        start: Date?, end: Date?, bounded: Bool
    ) -> AgentActivity {
        AgentActivity(
            sessionIDHash: session, client: client, startedAt: start ?? Date(),
            endedAt: end, workingDirectory: cwd, taskIDHash: taskHash,
            windowIsTaskBounded: bounded)
    }

    private func makeWindow(
        activity: AgentActivity, session: String, clientVersion: String?, taskHash: String,
        lifecycle: TaskLifecycleState, startKnown: Bool, endKnown: Bool, lastEventAt: Date,
        schemaKind: String, verification: VerificationState, path: String,
        startOffset: Int64?, endOffset: Int64?
    ) -> TaskWindow {
        TaskWindow(
            activityID: activity.id, sessionHash: session, taskHash: taskHash,
            clientKind: activity.client, clientVersion: clientVersion, lifecycle: lifecycle,
            startKnown: startKnown, endKnown: endKnown, lastEventAt: lastEventAt,
            schemaKind: schemaKind, verification: verification, sourceLogPath: path,
            eventStartOffset: startOffset, eventEndOffset: endOffset)
    }

    private func state(
        from runtime: Runtime, path: String, attributes: FileAttributes, now: Date
    ) -> SessionSyncState {
        SessionSyncState(
            filePath: path, fileIdentity: attributes.identity,
            sessionIDHash: runtime.sessionHash, byteOffset: runtime.committedOffset,
            fileSize: attributes.size, modifiedAt: attributes.modifiedAt, lastProcessed: now,
            workingDirectory: runtime.cwd, cursorVersion: 1,
            discardingOversized: runtime.discardingOversized,
            firstEventAt: runtime.firstEventAt, lastEventAt: runtime.lastEventAt,
            lastError: runtime.lastError, retryAfter: nil, lastScheduledAt: now)
    }

    // MARK: - Discovery / filesystem

    private struct FileAttributes {
        let identity: String
        let size: Int64
        let modifiedAt: Date?
    }

    private func refreshDiscovery(now: Date) {
        if let last = lastDiscovery, now.timeIntervalSince(last) < configuration.discoveryInterval {
            return
        }
        lastDiscovery = now
        let fileManager = FileManager.default
        let directory = configuration.sessionsDirectory
        guard fileManager.fileExists(atPath: directory.path) else {
            discovered = []
            return
        }
        let cutoff = now.addingTimeInterval(-Double(configuration.lookbackDays) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else {
            discovered = []
            return
        }
        var found: [Discovered] = []
        for case let url as URL in enumerator {
            guard found.count < configuration.maxDiscoveredFiles else { break }
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff { continue }
            found.append(
                Discovered(url: url, path: FilePaths.canonical(url.path), modifiedAt: modified))
        }
        discovered = found
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

    private func oversizedGap(path: String, now: Date) -> CoverageGap {
        CoverageGap(
            start: now, cause: .oversizedRecord, affectedRoots: [path], severity: .low)
    }

    // MARK: - Helpers

    private static func mapClient(_ originator: String?) -> AgentClientKind {
        guard let value = originator?.lowercased() else { return .unknown }
        if value.contains("desktop") { return .codexDesktop }
        if value.contains("cli") { return .codexCLI }
        if value.contains("vscode") || value.contains("ide") { return .codexIDE }
        return .unknown
    }

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
