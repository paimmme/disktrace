import Foundation

/// Single-writer SQLite store for aggregated history, evidence, alerts,
/// coverage gaps, minimal agent session metadata and monitor state.
///
/// The agent is the only writer; the UI reads snapshots. Observations are
/// append-only — decisions and rules never delete them.
public actor DiskTraceStore {
    let database: SQLiteDatabase
    var inventoryBudgetCache: (scanID: UUID, rows: Int, bytes: Int64)?
    private let databasePath: String?
    var databaseFilePath: String? { databasePath }

    public init(path: String, readOnly: Bool = false) throws {
        let database = try SQLiteDatabase(path: path, readOnly: readOnly)
        if !readOnly {
            try Migrations.assertWritable(database)
            try Migrations.migrate(database)
        }
        self.database = database
        self.databasePath = path == ":memory:" ? nil : path
    }

    private init(database: SQLiteDatabase, databasePath: String?) {
        self.database = database
        self.databasePath = databasePath
    }

    public static func inMemory() throws -> DiskTraceStore {
        let database = try SQLiteDatabase.inMemory()
        try Migrations.migrate(database)
        return DiskTraceStore(database: database, databasePath: nil)
    }

    // MARK: - Inserts

    public func insert(_ sample: VolumeSample) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO volume_samples
            (id, volume_id, observed_at, free_bytes, capacity_bytes, status)
            VALUES (?,?,?,?,?,?);
            """)
        try statement.run([
            .text(sample.id.uuidString), .text(sample.volumeID), .date(sample.observedAt),
            .int(sample.freeBytes), .int(sample.capacityBytes), .text(sample.status.rawValue),
        ])
    }

    /// Inserts a sample and records which method produced its free-space value.
    public func insert(_ sample: VolumeSample, method: VolumeMethod) throws {
        try insert(sample)
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO volume_measurement_context (sample_id, method) VALUES (?,?);")
        try statement.run([.text(sample.id.uuidString), .text(method.rawValue)])
    }

    public func insert(_ delta: DirectoryDelta) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO directory_changes
            (id, path_id, window_start, window_end, delta_allocated_bytes,
             before_allocated_bytes, after_allocated_bytes, checkpoint_id, calibration)
            VALUES (?,?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(delta.id.uuidString), .text(delta.pathID), .date(delta.windowStart),
            .date(delta.windowEnd), .int(delta.deltaAllocatedBytes),
            .int(delta.beforeAllocatedBytes), .int(delta.afterAllocatedBytes),
            .int(Int64(delta.checkpointID)), .text(delta.calibration.rawValue),
        ])
    }

    public func insert(_ evidence: Evidence) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO evidence
            (id, subject_id, source, scope, strength, identity, observed_at, limitation)
            VALUES (?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(evidence.id.uuidString), .text(evidence.subjectID.uuidString),
            .text(evidence.source.rawValue), .text(evidence.scope.rawValue),
            .int(Int64(evidence.strength.rawValue)), .optionalText(evidence.identity),
            .date(evidence.observedAt), .text(evidence.limitation),
        ])
    }

    public func insert(_ decision: AlertDecision) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO alert_decisions
            (id, rule_version, subject_id, action, reason, evidence_class,
             evidence_ids, cooldown_key, evaluated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """)
        let ids = (try? JSONEncoder().encode(decision.evidenceIDs.map(\.uuidString)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try statement.run([
            .text(decision.id.uuidString), .text(decision.ruleVersion),
            .text(decision.subjectID.uuidString), .text(decision.action.rawValue),
            .text(decision.reason.rawValue), .text(decision.evidenceClass.rawValue),
            .text(ids), .optionalText(decision.cooldownKey), .date(decision.evaluatedAt),
        ])
    }

    public func insert(_ gap: CoverageGap) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO coverage_gaps
            (id, start_at, end_at, cause, affected_roots, severity)
            VALUES (?,?,?,?,?,?);
            """)
        let roots = (try? JSONEncoder().encode(gap.affectedRoots))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try statement.run([
            .text(gap.id.uuidString), .date(gap.start), .optionalDate(gap.end),
            .text(gap.cause.rawValue), .text(roots), .text(gap.severity.rawValue),
        ])
    }

    public func insert(_ activity: AgentActivity) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO agent_activities
            (id, session_id_hash, client, started_at, ended_at, working_directory,
             task_id_hash, window_is_task_bounded)
            VALUES (?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(activity.id.uuidString), .text(activity.sessionIDHash),
            .text(activity.client.rawValue), .date(activity.startedAt),
            .optionalDate(activity.endedAt), .optionalText(activity.workingDirectory),
            .optionalText(activity.taskIDHash), .int(activity.windowIsTaskBounded ? 1 : 0),
        ])
    }

    // MARK: - Session sync (incremental, transactional)

    public func sessionSyncState(path: String) throws -> SessionSyncState? {
        let statement = try database.prepare(
            """
            SELECT file_path, file_identity, session_id_hash, byte_offset, file_size,
                   modified_at, last_processed, working_directory, cursor_version,
                   discarding_oversized, first_event_at, last_event_at, last_error,
                   retry_after, last_scheduled_at
            FROM session_sync WHERE file_path=?;
            """)
        guard try statement.run([.text(path)]) else { return nil }
        return SessionSyncState(
            filePath: statement.text(0),
            fileIdentity: statement.text(1),
            sessionIDHash: statement.optionalText(2),
            byteOffset: statement.int64(3),
            fileSize: statement.int64(4),
            modifiedAt: statement.optionalDate(5),
            lastProcessed: statement.date(6),
            workingDirectory: statement.optionalText(7),
            cursorVersion: statement.int(8),
            discardingOversized: statement.int64(9) != 0,
            firstEventAt: statement.optionalDate(10),
            lastEventAt: statement.optionalDate(11),
            lastError: statement.optionalText(12),
            retryAfter: statement.optionalDate(13),
            lastScheduledAt: statement.optionalDate(14))
    }

    /// Commits activity + task-window upserts, sync-cursor updates and gap
    /// records in one transaction, so a crash cannot advance a cursor past
    /// unrecorded activity or task state.
    public func applySessionBatch(
        activities: [AgentActivity],
        taskWindows: [TaskWindow],
        states: [SessionSyncState],
        gaps: [CoverageGap]
    ) throws {
        try database.transaction {
            for activity in activities { try insert(activity) }
            for window in taskWindows { try upsertTaskWindow(window) }
            let statement = try database.prepare(
                """
                INSERT OR REPLACE INTO session_sync
                (file_path, file_identity, session_id_hash, byte_offset, file_size,
                 modified_at, last_processed, working_directory, cursor_version,
                 discarding_oversized, first_event_at, last_event_at, last_error,
                 retry_after, last_scheduled_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """)
            for state in states {
                statement.reset()
                try statement.run([
                    .text(state.filePath), .text(state.fileIdentity),
                    .optionalText(state.sessionIDHash), .int(state.byteOffset),
                    .int(state.fileSize), .optionalDate(state.modifiedAt),
                    .date(state.lastProcessed), .optionalText(state.workingDirectory),
                    .int(Int64(state.cursorVersion)),
                    .int(state.discardingOversized ? 1 : 0),
                    .optionalDate(state.firstEventAt), .optionalDate(state.lastEventAt),
                    .optionalText(state.lastError), .optionalDate(state.retryAfter),
                    .optionalDate(state.lastScheduledAt),
                ])
            }
            for gap in gaps { try insert(gap) }
        }
    }

    /// Convenience for callers that only have activities and cursors.
    public func applySync(
        activities: [AgentActivity], states: [SessionSyncState], gaps: [CoverageGap] = []
    ) throws {
        try applySessionBatch(activities: activities, taskWindows: [], states: states, gaps: gaps)
    }

    public func upsertTaskWindow(_ window: TaskWindow) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO task_windows
            (activity_id, session_hash, task_hash, client_kind, client_version,
             lifecycle_state, start_known, end_known, last_event_at, schema_kind,
             verification_state, source_log_path, event_start_offset, event_end_offset)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(window.activityID.uuidString), .text(window.sessionHash),
            .text(window.taskHash), .text(window.clientKind.rawValue),
            .optionalText(window.clientVersion), .text(window.lifecycle.rawValue),
            .int(window.startKnown ? 1 : 0), .int(window.endKnown ? 1 : 0),
            .date(window.lastEventAt), .text(window.schemaKind),
            .text(window.verification.rawValue), .text(window.sourceLogPath),
            .optionalInt(window.eventStartOffset), .optionalInt(window.eventEndOffset),
        ])
    }

    public func taskWindows(activeSince: Date) throws -> [TaskWindow] {
        let statement = try database.prepare(
            """
            SELECT activity_id, session_hash, task_hash, client_kind, client_version,
                   lifecycle_state, start_known, end_known, last_event_at, schema_kind,
                   verification_state, source_log_path, event_start_offset, event_end_offset
            FROM task_windows
            WHERE lifecycle_state='running' OR last_event_at>=?
            ORDER BY last_event_at DESC;
            """)
        try statement.bind([.date(activeSince)])
        var result: [TaskWindow] = []
        while try statement.step() { result.append(taskWindow(statement)) }
        return result
    }

    public func latestTaskWindow(sessionHash: String) throws -> TaskWindow? {
        let statement = try database.prepare(
            """
            SELECT activity_id, session_hash, task_hash, client_kind, client_version,
                   lifecycle_state, start_known, end_known, last_event_at, schema_kind,
                   verification_state, source_log_path, event_start_offset, event_end_offset
            FROM task_windows WHERE session_hash=? ORDER BY last_event_at DESC LIMIT 1;
            """)
        guard try statement.run([.text(sessionHash)]) else { return nil }
        return taskWindow(statement)
    }

    public func openTaskWindows(sessionHash: String) throws -> [TaskWindow] {
        let statement = try database.prepare(
            """
            SELECT activity_id, session_hash, task_hash, client_kind, client_version,
                   lifecycle_state, start_known, end_known, last_event_at, schema_kind,
                   verification_state, source_log_path, event_start_offset, event_end_offset
            FROM task_windows WHERE session_hash=? AND lifecycle_state='running'
            ORDER BY last_event_at DESC;
            """)
        try statement.bind([.text(sessionHash)])
        var result: [TaskWindow] = []
        while try statement.step() { result.append(taskWindow(statement)) }
        return result
    }

    public func taskWindow(activityID: UUID) throws -> TaskWindow? {
        let statement = try database.prepare(
            """
            SELECT activity_id, session_hash, task_hash, client_kind, client_version,
                   lifecycle_state, start_known, end_known, last_event_at, schema_kind,
                   verification_state, source_log_path, event_start_offset, event_end_offset
            FROM task_windows WHERE activity_id=?;
            """)
        guard try statement.run([.text(activityID.uuidString)]) else { return nil }
        return taskWindow(statement)
    }

    public func saveClientVerification(_ verification: ClientVerification) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO client_verification
            (client_kind, client_version, schema_kind, result, verified_at, evidence_reference)
            VALUES (?,?,?,?,?,?);
            """)
        try statement.run([
            .text(verification.clientKind.rawValue), .text(verification.clientVersion),
            .text(verification.schemaKind), .text(verification.result.rawValue),
            .optionalDate(verification.verifiedAt), .optionalText(verification.evidenceReference),
        ])
    }

    public func clientVerification(
        clientKind: AgentClientKind, clientVersion: String, schemaKind: String
    ) throws -> ClientVerification? {
        let statement = try database.prepare(
            """
            SELECT client_kind, client_version, schema_kind, result, verified_at, evidence_reference
            FROM client_verification
            WHERE client_kind=? AND client_version=? AND schema_kind=?;
            """)
        guard try statement.run([
            .text(clientKind.rawValue), .text(clientVersion), .text(schemaKind),
        ]) else { return nil }
        return ClientVerification(
            clientKind: AgentClientKind(rawValue: statement.text(0)) ?? .unknown,
            clientVersion: statement.text(1),
            schemaKind: statement.text(2),
            result: VerificationState(rawValue: statement.text(3)) ?? .unverified,
            verifiedAt: statement.optionalDate(4),
            evidenceReference: statement.optionalText(5))
    }

    private func taskWindow(_ s: SQLiteStatement) -> TaskWindow {
        TaskWindow(
            activityID: UUID(uuidString: s.text(0)) ?? UUID(),
            sessionHash: s.text(1),
            taskHash: s.text(2),
            clientKind: AgentClientKind(rawValue: s.text(3)) ?? .unknown,
            clientVersion: s.optionalText(4),
            lifecycle: TaskLifecycleState(rawValue: s.text(5)) ?? .unknownStart,
            startKnown: s.int64(6) != 0,
            endKnown: s.int64(7) != 0,
            lastEventAt: s.date(8),
            schemaKind: s.text(9),
            verification: VerificationState(rawValue: s.text(10)) ?? .unverified,
            sourceLogPath: s.text(11),
            eventStartOffset: s.isNull(12) ? nil : s.int64(12),
            eventEndOffset: s.isNull(13) ? nil : s.int64(13))
    }

    public func save(_ rule: UserRule) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO user_rules
            (id, kind, path_pattern, created_at, expires_at, explanation, is_revoked)
            VALUES (?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(rule.id.uuidString), .text(rule.kind.rawValue), .text(rule.pathPattern),
            .date(rule.createdAt), .optionalDate(rule.expiresAt), .text(rule.explanation),
            .int(rule.isRevoked ? 1 : 0),
        ])
    }

    public func revokeRule(id: UUID) throws {
        let statement = try database.prepare("UPDATE user_rules SET is_revoked=1 WHERE id=?;")
        try statement.run([.text(id.uuidString)])
    }

    public func setState(_ key: String, _ value: String, at date: Date) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO monitor_state (key, value, updated_at) VALUES (?,?,?);")
        try statement.run([.text(key), .text(value), .date(date)])
    }

    // MARK: - Queries

    public func state(_ key: String) throws -> String? {
        let statement = try database.prepare("SELECT value FROM monitor_state WHERE key=?;")
        guard try statement.run([.text(key)]), !statement.isNull(0) else { return nil }
        return statement.text(0)
    }

    public func latestVolumeSample(volumeID: String) throws -> VolumeSample? {
        let statement = try database.prepare(
            "SELECT * FROM volume_samples WHERE volume_id=? ORDER BY observed_at DESC LIMIT 1;")
        guard try statement.run([.text(volumeID)]) else { return nil }
        return volumeSample(statement)
    }

    public func volumeSamples(volumeID: String, from: Date, to: Date) throws -> [VolumeSample] {
        let statement = try database.prepare(
            """
            SELECT * FROM volume_samples
            WHERE volume_id=? AND observed_at>=? AND observed_at<=?
            ORDER BY observed_at ASC;
            """)
        var result: [VolumeSample] = []
        try statement.bind([.text(volumeID), .date(from), .date(to)])
        while try statement.step() { result.append(volumeSample(statement)) }
        return result
    }

    /// All volumes' samples in a window, time-ordered — for the timeline chart.
    public func timelineSamples(from: Date, to: Date) throws -> [VolumeSample] {
        let statement = try database.prepare(
            """
            SELECT * FROM volume_samples
            WHERE observed_at>=? AND observed_at<=?
            ORDER BY observed_at ASC;
            """)
        var result: [VolumeSample] = []
        try statement.bind([.date(from), .date(to)])
        while try statement.step() { result.append(volumeSample(statement)) }
        return result
    }

    public func directoryDeltas(from: Date, to: Date, minimumGrowth: Int64 = 1) throws -> [DirectoryDelta] {
        let statement = try database.prepare(
            """
            SELECT * FROM directory_changes
            WHERE window_end>=? AND window_end<=? AND delta_allocated_bytes>=?
            ORDER BY delta_allocated_bytes DESC;
            """)
        var result: [DirectoryDelta] = []
        try statement.bind([.date(from), .date(to), .int(minimumGrowth)])
        while try statement.step() { result.append(directoryDelta(statement)) }
        return result
    }

    public func notifyingDecisions(from: Date, to: Date) throws -> [AlertDecision] {
        let statement = try database.prepare(
            """
            SELECT * FROM alert_decisions
            WHERE evaluated_at>=? AND evaluated_at<=? AND action!='silent'
            ORDER BY evaluated_at DESC;
            """)
        var result: [AlertDecision] = []
        try statement.bind([.date(from), .date(to)])
        while try statement.step() { result.append(alertDecision(statement)) }
        return result
    }

    public func decisions(from: Date, to: Date) throws -> [AlertDecision] {
        let statement = try database.prepare(
            "SELECT * FROM alert_decisions WHERE evaluated_at>=? AND evaluated_at<=? ORDER BY evaluated_at DESC;")
        try statement.bind([.date(from), .date(to)])
        var result: [AlertDecision] = []
        while try statement.step() { result.append(alertDecision(statement)) }
        return result
    }

    public func evidence(subjectID: UUID) throws -> [Evidence] {
        let statement = try database.prepare("SELECT * FROM evidence WHERE subject_id=? ORDER BY observed_at DESC;")
        try statement.bind([.text(subjectID.uuidString)])
        var result: [Evidence] = []
        while try statement.step() {
            result.append(Evidence(
                id: UUID(uuidString: statement.text(0)) ?? UUID(), subjectID: subjectID,
                source: EvidenceSource(rawValue: statement.text(2)) ?? .directoryNameHint,
                scope: EvidenceScope(rawValue: statement.text(3)) ?? .timeWindowOnly,
                strength: EvidenceStrength(rawValue: statement.int(4)) ?? .weak,
                identity: statement.optionalText(5), observedAt: statement.date(6),
                limitation: statement.text(7)))
        }
        return result
    }

    public func lastAlertDate(cooldownKey: String) throws -> Date? {
        let statement = try database.prepare(
            """
            SELECT MAX(evaluated_at) FROM alert_decisions
            WHERE cooldown_key=? AND action='notifyAgentAnomaly';
            """)
        guard try statement.run([.text(cooldownKey)]), !statement.isNull(0) else { return nil }
        return statement.date(0)
    }

    public func userRules() throws -> [UserRule] {
        let statement = try database.prepare("SELECT * FROM user_rules ORDER BY created_at ASC;")
        var result: [UserRule] = []
        while try statement.step() {
            result.append(
                UserRule(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    kind: UserRuleKind(rawValue: statement.text(1)) ?? .watch,
                    pathPattern: statement.text(2),
                    createdAt: statement.date(3),
                    expiresAt: statement.optionalDate(4),
                    explanation: statement.text(5),
                    isRevoked: statement.int64(6) != 0))
        }
        return result
    }

    public func activities(from: Date, to: Date) throws -> [AgentActivity] {
        let statement = try database.prepare(
            "SELECT * FROM agent_activities WHERE started_at<=? AND (ended_at IS NULL OR ended_at>=?) ORDER BY started_at ASC;")
        var result: [AgentActivity] = []
        try statement.bind([.date(to), .date(from)])
        while try statement.step() {
            result.append(
                AgentActivity(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    sessionIDHash: statement.text(1),
                    client: AgentClientKind(rawValue: statement.text(2)) ?? .unknown,
                    startedAt: statement.date(3),
                    endedAt: statement.optionalDate(4),
                    workingDirectory: statement.optionalText(5),
                    taskIDHash: statement.optionalText(6),
                    windowIsTaskBounded: statement.int64(7) != 0))
        }
        return result
    }

    public func coverageGaps(from: Date) throws -> [CoverageGap] {
        let statement = try database.prepare(
            "SELECT * FROM coverage_gaps WHERE start_at>=? ORDER BY start_at DESC;")
        var result: [CoverageGap] = []
        try statement.bind([.date(from)])
        while try statement.step() {
            let roots = (try? JSONDecoder().decode(
                [String].self, from: Data(statement.text(4).utf8))) ?? []
            result.append(
                CoverageGap(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    start: statement.date(1),
                    end: statement.optionalDate(2),
                    cause: CoverageGapCause(rawValue: statement.text(3)) ?? .agentRestart,
                    affectedRoots: roots,
                    severity: CoverageSeverity(rawValue: statement.text(5)) ?? .low))
        }
        return result
    }

    public func rowCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in [
            "volume_samples", "directory_changes", "evidence", "alert_decisions",
            "coverage_gaps", "agent_activities", "user_rules", "session_sync",
            "task_windows", "client_verification",
        ] {
            let statement = try database.prepare("SELECT COUNT(*) FROM \(table);")
            counts[table] = (try statement.step()) ? statement.int(0) : 0
        }
        return counts
    }

    /// Both the in-use page estimate and the real file sizes (db, WAL, SHM).
    public func spaceReport() -> SpaceReport {
        var pageCount: Int64 = 0
        var freeList: Int64 = 0
        var pageSize: Int64 = 0
        if let statement = try? database.prepare("PRAGMA page_count;"),
            (try? statement.step()) == true
        {
            pageCount = statement.int64(0)
        }
        if let statement = try? database.prepare("PRAGMA freelist_count;"),
            (try? statement.step()) == true
        {
            freeList = statement.int64(0)
        }
        if let statement = try? database.prepare("PRAGMA page_size;"),
            (try? statement.step()) == true
        {
            pageSize = statement.int64(0)
        }
        var databaseBytes: Int64 = 0
        var walBytes: Int64 = 0
        var shmBytes: Int64 = 0
        if let path = databasePath {
            databaseBytes = Self.fileSize(path)
            walBytes = Self.fileSize(path + "-wal")
            shmBytes = Self.fileSize(path + "-shm")
        }
        return SpaceReport(
            pageCount: pageCount, freeListPages: freeList, pageSize: pageSize,
            effectiveBytes: max(0, pageCount - freeList) * pageSize,
            databaseBytes: databaseBytes, walBytes: walBytes, shmBytes: shmBytes)
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    /// Retained for compatibility; equals the in-use page estimate.
    public func estimatedDatabaseBytes() -> Int64 {
        spaceReport().effectiveBytes
    }

    func rawExecute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try database.prepare(sql)
        try statement.run(values)
    }

    func count(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        let statement = try database.prepare(sql)
        guard try statement.run(values) else { return 0 }
        return statement.int(0)
    }

    // MARK: - Retention

    /// Prune history by per-table age, then reclaim space. Pruning and
    /// reclamation are independent: pruning is judged by rows deleted, and
    /// reclamation by the actual file footprint.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date) throws -> RetentionReport {
        var report = try pruneHistory(policy, now: now)
        let (reclaimed, space) = try reclaimSpace(policy)
        report.reclaimedBytes = reclaimed
        report.space = space
        return report
    }

    /// Age-based pruning per table, plus bounded quota-driven row deletion.
    /// User rules and open coverage gaps are never touched.
    @discardableResult
    public func pruneHistory(_ policy: RetentionPolicy, now: Date) throws -> RetentionReport {
        var report = RetentionReport()
        func cutoff(_ days: Int) -> SQLiteValue {
            .date(now.addingTimeInterval(-Double(days) * 86_400))
        }
        let cutoffDetailed = now.addingTimeInterval(-Double(policy.samplesDetailedDays) * 86_400)
        let cutoffHourly = now.addingTimeInterval(-Double(policy.samplesHourlyDays) * 86_400)

        report.evidenceDeleted = try deleteCount(
            "DELETE FROM evidence WHERE observed_at < ?;", [cutoff(policy.evidenceDays)])
        report.deltasDeleted = try deleteCount(
            "DELETE FROM directory_changes WHERE window_end < ?;", [cutoff(policy.deltasDays)])
        report.decisionsDeleted = try deleteCount(
            "DELETE FROM alert_decisions WHERE evaluated_at < ?;", [cutoff(policy.decisionsDays)])
        report.activitiesDeleted = try deleteCount(
            "DELETE FROM agent_activities WHERE started_at < ?;", [cutoff(policy.activitiesDays)])
        // Open gaps (end_at IS NULL) are protected.
        report.gapsDeleted = try deleteCount(
            "DELETE FROM coverage_gaps WHERE end_at IS NOT NULL AND end_at < ?;",
            [cutoff(policy.gapsDays)])
        // Processed change hints and old presence checks.
        report.hintsDeleted = try deleteCount(
            "DELETE FROM change_hints WHERE processing_state='processed' AND last_observed_at < ?;",
            [cutoff(policy.hintsDays)])
        _ = try deleteCount(
            "DELETE FROM presence_checks WHERE checked_at IS NOT NULL AND checked_at < ?;",
            [cutoff(policy.presenceChecksDays)])
        // Mark events whose detail is about to be trimmed, then trim detail.
        report.eventsMarkedExpired = try deleteCount(
            "UPDATE storage_events SET status='detailExpired' WHERE window_end < ? AND status<>'detailExpired';",
            [cutoff(policy.fileChangesDays)])
        report.fileChangesDeleted = try deleteCount(
            "DELETE FROM file_changes WHERE observed_at < ?;", [cutoff(policy.fileChangesDays)])
        report.eventsDeleted = try deleteCount(
            "DELETE FROM storage_events WHERE window_end < ?;", [cutoff(policy.eventsDays)])

        report.samplesDownsampled += try downsampleVolumeSamples(
            from: cutoffHourly, to: cutoffDetailed, seconds: 3_600)
        report.samplesDownsampled += try downsampleVolumeSamples(
            from: Date(timeIntervalSince1970: 0), to: cutoffHourly, seconds: 86_400)

        report.rowsDeletedForQuota = try enforceQuota(policy)
        report.space = spaceReport()
        return report
    }

    /// Deletes oldest rows across tables in batches until the in-use page
    /// estimate is within the soft quota or the per-cycle budget is exhausted.
    /// It does not require the page count to fall — deletes move pages to the
    /// freelist, which already lowers `effectiveBytes`.
    private func enforceQuota(_ policy: RetentionPolicy) throws -> Int {
        var deleted = 0
        var space = spaceReport()
        var guardCounter = 0
        while space.effectiveBytes > policy.softQuotaBytes
            && deleted < policy.maxRowsPerCycle && guardCounter < 200
        {
            guardCounter += 1
            var batch = 0
            batch += try deleteCount(
                "DELETE FROM volume_samples WHERE id IN (SELECT id FROM volume_samples ORDER BY observed_at ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM directory_changes WHERE id IN (SELECT id FROM directory_changes ORDER BY window_end ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM alert_decisions WHERE id IN (SELECT id FROM alert_decisions ORDER BY evaluated_at ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM evidence WHERE id IN (SELECT id FROM evidence ORDER BY observed_at ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM file_changes WHERE id IN (SELECT id FROM file_changes ORDER BY observed_at ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM change_hints WHERE id IN (SELECT id FROM change_hints ORDER BY last_observed_at ASC LIMIT 500);",
                [])
            batch += try deleteCount(
                "DELETE FROM storage_events WHERE id IN (SELECT id FROM storage_events ORDER BY window_end ASC LIMIT 500);",
                [])
            if batch == 0 { break }
            deleted += batch
            let next = spaceReport()
            space = next
        }
        return deleted
    }

    /// Space reclamation, separate from pruning: checkpoint the WAL (deferred if
    /// a reader holds it) and optionally run an incremental vacuum. A full
    /// `VACUUM` is deliberately never run automatically.
    public func reclaimSpace(_ policy: RetentionPolicy) throws -> (Int64, SpaceReport) {
        let before = spaceReport()
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        if policy.incrementalVacuum, isIncrementalAutoVacuum {
            try? database.execute("PRAGMA incremental_vacuum;")
        }
        let after = spaceReport()
        return (max(0, before.totalFileBytes - after.totalFileBytes), after)
    }

    private var isIncrementalAutoVacuum: Bool {
        guard let statement = try? database.prepare("PRAGMA auto_vacuum;"),
            (try? statement.step()) == true
        else { return false }
        return statement.int(0) >= 1
    }

    private func deleteCount(_ sql: String, _ values: [SQLiteValue]) throws -> Int {
        let statement = try database.prepare(sql)
        try statement.run(values)
        return database.changes
    }

    private func downsampleVolumeSamples(
        from start: Date, to end: Date, seconds: TimeInterval
    ) throws -> Int {
        guard end > start else { return 0 }
        let select = try database.prepare(
            """
            SELECT volume_id, observed_at, free_bytes, capacity_bytes, status
            FROM volume_samples WHERE observed_at>=? AND observed_at<? ORDER BY observed_at ASC;
            """)
        struct Key: Hashable { let volume: String; let bucket: Int }
        var sums: [Key: (free: Int64, capacity: Int64, count: Int64, available: Bool)] = [:]
        var originals = 0
        try select.bind([.date(start), .date(end)])
        while try select.step() {
            originals += 1
            let volume = select.text(0)
            let bucket = Int(select.date(1).timeIntervalSince1970 / seconds)
            let key = Key(volume: volume, bucket: bucket)
            let available = select.text(4) == AvailabilityStatus.available.rawValue
            var entry = sums[key] ?? (0, 0, 0, false)
            entry.free += select.int64(2)
            entry.capacity += select.int64(3)
            entry.count += 1
            entry.available = entry.available || available
            sums[key] = entry
        }
        guard originals > 0 else { return 0 }

        try deleteCount("DELETE FROM volume_samples WHERE observed_at>=? AND observed_at<?;", [
            .date(start), .date(end),
        ])
        for (key, value) in sums {
            let observed = Date(timeIntervalSince1970: Double(key.bucket) * seconds)
            let sample = VolumeSample(
                volumeID: key.volume,
                observedAt: observed > start ? observed : start,
                freeBytes: value.count > 0 ? value.free / value.count : 0,
                capacityBytes: value.count > 0 ? value.capacity / value.count : 0,
                status: value.available ? .available : .unavailable)
            try insert(sample)
        }
        return originals
    }

    // MARK: - Row mapping

    private func volumeSample(_ s: SQLiteStatement) -> VolumeSample {
        VolumeSample(
            id: UUID(uuidString: s.text(0)) ?? UUID(),
            volumeID: s.text(1),
            observedAt: s.date(2),
            freeBytes: s.int64(3),
            capacityBytes: s.int64(4),
            status: AvailabilityStatus(rawValue: s.text(5)) ?? .unavailable)
    }

    private func directoryDelta(_ s: SQLiteStatement) -> DirectoryDelta {
        DirectoryDelta(
            id: UUID(uuidString: s.text(0)) ?? UUID(),
            pathID: s.text(1),
            windowStart: s.date(2),
            windowEnd: s.date(3),
            deltaAllocatedBytes: s.int64(4),
            beforeAllocatedBytes: s.int64(5),
            afterAllocatedBytes: s.int64(6),
            checkpointID: UInt64(s.int64(7)),
            calibration: CalibrationStatus(rawValue: s.text(8)) ?? .stale)
    }

    private func alertDecision(_ s: SQLiteStatement) -> AlertDecision {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(s.text(6).utf8))) ?? []
        return AlertDecision(
            id: UUID(uuidString: s.text(0)) ?? UUID(),
            ruleVersion: s.text(1),
            subjectID: UUID(uuidString: s.text(2)) ?? UUID(),
            action: AlertAction(rawValue: s.text(3)) ?? .silent,
            reason: AlertReason(rawValue: s.text(4)) ?? .unknownSource,
            evidenceClass: EvidenceClass(rawValue: s.text(5)) ?? .unknown,
            evidenceIDs: ids.compactMap(UUID.init(uuidString:)),
            cooldownKey: s.optionalText(7),
            evaluatedAt: s.date(8))
    }
}
