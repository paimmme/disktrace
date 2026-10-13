import Foundation

/// Single-writer SQLite store for aggregated history, evidence, alerts,
/// coverage gaps, minimal agent session metadata and monitor state.
///
/// The agent is the only writer; the UI reads snapshots. Observations are
/// append-only — decisions and rules never delete them.
public actor DiskTraceStore {
    private let database: SQLiteDatabase

    public init(path: String) throws {
        let database = try SQLiteDatabase(path: path)
        try Migrations.migrate(database)
        self.database = database
    }

    private init(database: SQLiteDatabase) {
        self.database = database
    }

    public static func inMemory() throws -> DiskTraceStore {
        let database = try SQLiteDatabase.inMemory()
        try Migrations.migrate(database)
        return DiskTraceStore(database: database)
    }

    // MARK: - Inserts

    public func insert(_ sample: VolumeSample) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO volume_samples VALUES (?,?,?,?,?,?);")
        try statement.run([
            .text(sample.id.uuidString), .text(sample.volumeID), .date(sample.observedAt),
            .int(sample.freeBytes), .int(sample.capacityBytes), .text(sample.status.rawValue),
        ])
    }

    public func insert(_ delta: DirectoryDelta) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO directory_changes VALUES (?,?,?,?,?,?,?,?,?);")
        try statement.run([
            .text(delta.id.uuidString), .text(delta.pathID), .date(delta.windowStart),
            .date(delta.windowEnd), .int(delta.deltaAllocatedBytes),
            .int(delta.beforeAllocatedBytes), .int(delta.afterAllocatedBytes),
            .int(Int64(delta.checkpointID)), .text(delta.calibration.rawValue),
        ])
    }

    public func insert(_ evidence: Evidence) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO evidence VALUES (?,?,?,?,?,?,?,?);")
        try statement.run([
            .text(evidence.id.uuidString), .text(evidence.subjectID.uuidString),
            .text(evidence.source.rawValue), .text(evidence.scope.rawValue),
            .int(Int64(evidence.strength.rawValue)), .optionalText(evidence.identity),
            .date(evidence.observedAt), .text(evidence.limitation),
        ])
    }

    public func insert(_ decision: AlertDecision) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO alert_decisions VALUES (?,?,?,?,?,?,?,?,?);")
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
            "INSERT OR REPLACE INTO coverage_gaps VALUES (?,?,?,?,?,?);")
        let roots = (try? JSONEncoder().encode(gap.affectedRoots))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try statement.run([
            .text(gap.id.uuidString), .date(gap.start), .optionalDate(gap.end),
            .text(gap.cause.rawValue), .text(roots), .text(gap.severity.rawValue),
        ])
    }

    public func insert(_ activity: AgentActivity) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO agent_activities VALUES (?,?,?,?,?,?);")
        try statement.run([
            .text(activity.id.uuidString), .text(activity.sessionIDHash),
            .text(activity.client.rawValue), .date(activity.startedAt),
            .optionalDate(activity.endedAt), .optionalText(activity.workingDirectory),
        ])
    }

    public func save(_ rule: UserRule) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO user_rules VALUES (?,?,?,?,?,?,?);")
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
            "INSERT OR REPLACE INTO monitor_state VALUES (?,?,?);")
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
                    workingDirectory: statement.optionalText(5)))
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
            "coverage_gaps", "agent_activities", "user_rules",
        ] {
            let statement = try database.prepare("SELECT COUNT(*) FROM \(table);")
            counts[table] = (try statement.step()) ? statement.int(0) : 0
        }
        return counts
    }

    /// Estimated on-disk footprint including the database file (WAL/SHM are
    /// accounted by the caller through the filesystem).
    public func estimatedDatabaseBytes() -> Int64 {
        var pageCount: Int64 = 0
        var pageSize: Int64 = 0
        if let statement = try? database.prepare("PRAGMA page_count;"),
            (try? statement.step()) == true
        {
            pageCount = statement.int64(0)
        }
        if let statement = try? database.prepare("PRAGMA page_size;"),
            (try? statement.step()) == true
        {
            pageSize = statement.int64(0)
        }
        return pageCount * pageSize
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

    /// Tiered downsampling plus quota enforcement. Idempotent: it only removes
    /// reconstructable rows and never rewrites surviving observations.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date) throws -> RetentionReport {
        var report = RetentionReport()
        let cutoffDetailed = now.addingTimeInterval(-Double(policy.detailedDays) * 86_400)
        let cutoffHourly = now.addingTimeInterval(-Double(policy.hourlySummaryDays) * 86_400)

        report.evidenceDeleted = try deleteCount(
            "DELETE FROM evidence WHERE observed_at < ?;", [.date(cutoffDetailed)])
        report.deltasDeleted = try deleteCount(
            "DELETE FROM directory_changes WHERE window_end < ?;", [.date(cutoffHourly)])

        report.samplesDownsampled += try downsampleVolumeSamples(
            from: cutoffHourly, to: cutoffDetailed, seconds: 3_600)
        report.samplesDownsampled += try downsampleVolumeSamples(
            from: Date(timeIntervalSince1970: 0), to: cutoffHourly, seconds: 86_400)

        var bytes = estimatedDatabaseBytes()
        var guardCounter = 0
        while bytes > policy.softQuotaBytes && guardCounter < 1_000 {
            guardCounter += 1
            let removedSamples = try deleteCount(
                "DELETE FROM volume_samples WHERE id IN (SELECT id FROM volume_samples ORDER BY observed_at ASC LIMIT 500);",
                [])
            let removedDeltas = try deleteCount(
                "DELETE FROM directory_changes WHERE id IN (SELECT id FROM directory_changes ORDER BY window_end ASC LIMIT 500);",
                [])
            if removedSamples == 0 && removedDeltas == 0 { break }
            report.samplesDeletedForQuota += removedSamples + removedDeltas
            let next = estimatedDatabaseBytes()
            if next >= bytes { break }
            bytes = next
        }
        report.estimatedBytes = bytes
        return report
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
