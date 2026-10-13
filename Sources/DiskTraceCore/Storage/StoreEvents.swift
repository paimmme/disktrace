import Foundation

/// User-understandable events, task links, presence checks and feedback.
extension DiskTraceStore {

    @discardableResult
    public func upsertEvents(_ assembled: [EventAssembler.Assembled], at date: Date) throws -> Int {
        guard !assembled.isEmpty else { return 0 }
        let eventStmt = try database.prepare(
            """
            INSERT INTO storage_events
            (id, root_id, scope_path, window_start, window_end, gross_added_bytes,
             gross_removed_bytes, net_bytes, measurement_state, reason_category,
             attribution_class, candidate_count, unassigned_bytes, status, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,
                attribution_class=excluded.attribution_class,
                candidate_count=excluded.candidate_count, measurement_state=excluded.measurement_state,
                status=excluded.status;

            """)
        let fileStmt = try database.prepare(
            "INSERT OR REPLACE INTO event_files (event_id, change_id) VALUES (?,?);")
        let linkStmt = try database.prepare(
            """
            INSERT OR REPLACE INTO task_links
            (event_id, activity_id, link_state, link_basis, candidate_bytes,
             algorithm_version, limitation)
            VALUES (?,?,?,?,?,?,?);
            """)
        try database.transaction {
            for item in assembled {
                let event = item.event
                eventStmt.reset()
                try eventStmt.run([
                    .text(event.id.uuidString), .text(event.rootID.uuidString),
                    .text(event.scopePath), .date(event.windowStart), .date(event.windowEnd),
                    .optionalInt(event.grossAddedBytes), .optionalInt(event.grossRemovedBytes),
                    .optionalInt(event.netBytes), .text(event.measurement.rawValue),
                    .text(event.reasonCategory.rawValue), .text(event.attributionClass.rawValue),
                    .int(Int64(event.candidateCount)), .optionalInt(event.unassignedBytes),
                    .text(event.status.rawValue), .date(event.createdAt), .date(event.updatedAt),
                ])
                for changeID in item.changeIDs {
                    fileStmt.reset()
                    try fileStmt.run([.text(event.id.uuidString), .text(changeID.uuidString)])
                }
                try rawExecute("""
                    UPDATE storage_events SET
                      net_bytes=(SELECT CASE WHEN COUNT(*)=COUNT(c.delta_allocated) THEN SUM(c.delta_allocated) ELSE NULL END FROM event_files f JOIN file_changes c ON c.id=f.change_id WHERE f.event_id=?),
                      gross_added_bytes=(SELECT COALESCE(SUM(MAX(c.delta_allocated,0)),0) FROM event_files f JOIN file_changes c ON c.id=f.change_id WHERE f.event_id=?),
                      gross_removed_bytes=(SELECT COALESCE(SUM(MIN(c.delta_allocated,0)),0) FROM event_files f JOIN file_changes c ON c.id=f.change_id WHERE f.event_id=?),
                      attribution_class=CASE
                        WHEN EXISTS(SELECT 1 FROM event_feedback WHERE event_id=? AND revoked_at IS NULL AND feedback_kind='confirmUser') THEN 'userConfirmed'
                        WHEN EXISTS(SELECT 1 FROM event_files f JOIN file_changes c ON c.id=f.change_id WHERE f.event_id=? AND (c.timing_precision<>'liveHintWindow' OR c.measurement_state<>'measured')) THEN 'unknown'
                        ELSE attribution_class END
                    WHERE id=?;
                    """, Array(repeating: .text(event.id.uuidString), count: 6))
                for link in item.links {
                    linkStmt.reset()
                    try linkStmt.run([
                        .text(link.eventID.uuidString), .text(link.activityID.uuidString),
                        .text(link.state.rawValue), .text(link.basis),
                        .optionalInt(link.candidateBytes), .text(link.algorithmVersion),
                        .text(link.limitation),
                    ])
                }
                try rawExecute("""
                    UPDATE storage_events SET
                      candidate_count=(SELECT COUNT(DISTINCT activity_id) FROM task_links WHERE event_id=?),
                      unassigned_bytes=CASE WHEN NOT EXISTS(SELECT 1 FROM task_links WHERE event_id=?) THEN net_bytes ELSE NULL END,
                      measurement_state=CASE WHEN net_bytes IS NULL THEN 'beforeUnknown' ELSE measurement_state END,
                      attribution_class=CASE WHEN attribution_class='userConfirmed' THEN attribution_class
                        WHEN (SELECT COUNT(DISTINCT activity_id) FROM task_links WHERE event_id=?)>1 THEN 'unknown' ELSE attribution_class END
                    WHERE id=?;
                    """, Array(repeating: .text(event.id.uuidString), count: 4))
            }
        }
        return assembled.count
    }

    public func event(id: UUID) throws -> StorageEvent? {
        let s = try database.prepare("SELECT * FROM storage_events WHERE id=?;")
        guard try s.run([.text(id.uuidString)]) else { return nil }
        return storageEvent(s)
    }

    // MARK: - Queries (keyset paging)

    public func queryEvents(
        rootID: UUID?, from: Date, to: Date, limit: Int = 100, before: Date? = nil, beforeID: UUID? = nil
    ) throws -> [StorageEvent] {
        var sql = "SELECT * FROM storage_events WHERE window_end>=? AND window_start<=?"
        if rootID != nil { sql += " AND root_id=?" }
        if before != nil { sql += beforeID == nil ? " AND window_end<?" : " AND (window_end<? OR (window_end=? AND id<?))" }
        sql += " ORDER BY window_end DESC, id DESC LIMIT ?;"
        let statement = try database.prepare(sql)
        var values: [SQLiteValue] = [.date(from), .date(to)]
        if let rootID { values.append(.text(rootID.uuidString)) }
        if let before {
            values.append(.date(before))
            if let beforeID { values += [.date(before), .text(beforeID.uuidString)] }
        }
        values.append(.int(Int64(limit)))
        try statement.bind(values)
        var result: [StorageEvent] = []
        while try statement.step() { result.append(storageEvent(statement)) }
        return result
    }

    public func queryFileChanges(eventID: UUID, limit: Int = 100, offset: Int = 0) throws -> [FileChange] {
        let statement = try database.prepare(
            """
            SELECT c.* FROM file_changes c
            JOIN event_files e ON e.change_id = c.id
            WHERE e.event_id=?
            ORDER BY ABS(COALESCE(c.delta_allocated,0)) DESC, c.id LIMIT ? OFFSET ?;
            """)
        try statement.bind([.text(eventID.uuidString), .int(Int64(max(1, min(limit, 1000)))), .int(Int64(max(0, offset)))])
        var result: [FileChange] = []
        while try statement.step() { result.append(fileChange(statement)) }
        return result
    }

    public func queryTaskCandidates(eventID: UUID) throws -> [TaskLink] {
        let statement = try database.prepare(
            "SELECT * FROM task_links WHERE event_id=? ORDER BY link_state;")
        try statement.bind([.text(eventID.uuidString)])
        var result: [TaskLink] = []
        while try statement.step() {
            result.append(
                TaskLink(
                    eventID: eventID,
                    activityID: UUID(uuidString: statement.text(1)) ?? UUID(),
                    state: TaskLinkState(rawValue: statement.text(2)) ?? .timeOnly,
                    basis: statement.text(3),
                    candidateBytes: statement.isNull(4) ? nil : statement.int64(4),
                    algorithmVersion: statement.text(5),
                    limitation: statement.text(6)))
        }
        return result
    }

    func storageEvent(_ s: SQLiteStatement) -> StorageEvent {
        StorageEvent(
            id: UUID(uuidString: s.text(0)) ?? UUID(),
            rootID: UUID(uuidString: s.text(1)) ?? UUID(),
            scopePath: s.text(2), windowStart: s.date(3), windowEnd: s.date(4),
            grossAddedBytes: s.isNull(5) ? nil : s.int64(5),
            grossRemovedBytes: s.isNull(6) ? nil : s.int64(6),
            netBytes: s.isNull(7) ? nil : s.int64(7),
            measurement: MeasurementState(rawValue: s.text(8)) ?? .measured,
            reasonCategory: ReasonCategory(rawValue: s.text(9)) ?? .unknown,
            attributionClass: EventAttributionClass(rawValue: s.text(10)) ?? .unknown,
            candidateCount: s.int(11),
            unassignedBytes: s.isNull(12) ? nil : s.int64(12),
            status: EventStatus(rawValue: s.text(13)) ?? .ready,
            createdAt: s.date(14), updatedAt: s.date(15))
    }

    // MARK: - Presence checks

    public func schedulePresence(changeID: UUID, at date: Date, result: PresenceResult = .unknown) throws {
        let statement = try database.prepare(
            "INSERT OR IGNORE INTO presence_checks (change_id, scheduled_at, result) VALUES (?,?,?);")
        try statement.run([.text(changeID.uuidString), .date(date), .text(result.rawValue)])
    }

    public func duePresenceChecks(now: Date, limit: Int = 100) throws -> [PresenceCheck] {
        let statement = try database.prepare(
            """
            SELECT change_id, scheduled_at, checked_at, result, current_identity, current_allocated
            FROM presence_checks WHERE checked_at IS NULL AND scheduled_at<=?
            ORDER BY scheduled_at ASC LIMIT ?;
            """)
        try statement.bind([.date(now), .int(Int64(limit))])
        var result: [PresenceCheck] = []
        while try statement.step() {
            result.append(
                PresenceCheck(
                    changeID: UUID(uuidString: statement.text(0)) ?? UUID(),
                    scheduledAt: statement.date(1), checkedAt: statement.optionalDate(2),
                    result: PresenceResult(rawValue: statement.text(3)) ?? .unknown,
                    currentIdentity: statement.optionalText(4),
                    currentAllocated: statement.isNull(5) ? nil : statement.int64(5)))
        }
        return result
    }

    public func recordPresence(_ check: PresenceCheck) throws {
        let statement = try database.prepare(
            """
            UPDATE presence_checks SET checked_at=?, result=?, current_identity=?, current_allocated=?
            WHERE change_id=? AND scheduled_at=?;
            """)
        try statement.run([
            .optionalDate(check.checkedAt), .text(check.result.rawValue),
            .optionalText(check.currentIdentity), .optionalInt(check.currentAllocated),
            .text(check.changeID.uuidString), .date(check.scheduledAt),
        ])
    }

    public func presenceChecks(changeID: UUID) throws -> [PresenceCheck] {
        let statement = try database.prepare(
            """
            SELECT change_id, scheduled_at, checked_at, result, current_identity, current_allocated
            FROM presence_checks WHERE change_id=? ORDER BY scheduled_at;
            """)
        try statement.bind([.text(changeID.uuidString)])
        var result: [PresenceCheck] = []
        while try statement.step() {
            result.append(
                PresenceCheck(
                    changeID: changeID, scheduledAt: statement.date(1),
                    checkedAt: statement.optionalDate(2),
                    result: PresenceResult(rawValue: statement.text(3)) ?? .unknown,
                    currentIdentity: statement.optionalText(4),
                    currentAllocated: statement.isNull(5) ? nil : statement.int64(5)))
        }
        return result
    }

    // MARK: - User feedback

    public func addEventFeedback(eventID: UUID, kind: String, at date: Date) throws {
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO event_feedback (id, event_id, feedback_kind, created_at, revoked_at) VALUES (?,?,?,?,NULL);")
        try statement.run([
            .text(Fingerprint.uuid("feedback|" + eventID.uuidString + "|" + kind).uuidString), .text(eventID.uuidString), .text(kind), .date(date),
        ])
        // Confirming an event sets its attribution to userConfirmed (idempotent).
        try rawExecute(
            "UPDATE storage_events SET attribution_class='userConfirmed', updated_at=? WHERE id=?;",
            [.date(date), .text(eventID.uuidString)])
    }

    public func revokeEventFeedback(eventID: UUID, at date: Date) throws {
        try rawExecute(
            "UPDATE event_feedback SET revoked_at=? WHERE event_id=? AND revoked_at IS NULL;",
            [.date(date), .text(eventID.uuidString)])
        try rawExecute(
            "UPDATE storage_events SET attribution_class='unknown', updated_at=? WHERE id=?;",
            [.date(date), .text(eventID.uuidString)])
    }

    public func activeEventFeedback(eventID: UUID) throws -> [EventFeedback] {
        let statement = try database.prepare(
            "SELECT id, event_id, feedback_kind, created_at, revoked_at FROM event_feedback WHERE event_id=? AND revoked_at IS NULL;")
        try statement.bind([.text(eventID.uuidString)])
        var result: [EventFeedback] = []
        while try statement.step() {
            result.append(
                EventFeedback(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    eventID: eventID, kind: statement.text(2), createdAt: statement.date(3)))
        }
        return result
    }
}
