import Foundation

/// Scopes, scan generations, file inventory, concrete file changes and durable
/// change hints. Split from the core store file only for readability; it uses
/// the same single writer connection.
extension DiskTraceStore {

    // MARK: - Roots

    @discardableResult
    public func ensureRoot(
        canonicalPath: String, volumeID: String?, configRevision: Int, at date: Date
    ) throws -> MonitoredRoot {
        let id = MonitoredRoot.stableID(canonicalPath: canonicalPath)
        let statement = try database.prepare(
            """
            INSERT INTO monitored_roots (id, canonical_path, volume_id, enabled, config_revision, created_at)
            VALUES (?,?,?,1,?,?)
            ON CONFLICT(canonical_path) DO UPDATE SET volume_id=excluded.volume_id,
                config_revision=excluded.config_revision;
            """)
        try statement.run([
            .text(id.uuidString), .text(canonicalPath), .optionalText(volumeID),
            .int(Int64(configRevision)), .date(date),
        ])
        return try root(id: id) ?? MonitoredRoot(
            id: id, canonicalPath: canonicalPath, volumeID: volumeID, enabled: true,
            configRevision: configRevision)
    }

    public func root(id: UUID) throws -> MonitoredRoot? {
        let statement = try database.prepare("SELECT * FROM monitored_roots WHERE id=?;")
        guard try statement.run([.text(id.uuidString)]) else { return nil }
        return MonitoredRoot(
            id: UUID(uuidString: statement.text(0)) ?? id,
            canonicalPath: statement.text(1),
            volumeID: statement.optionalText(2),
            enabled: statement.int64(3) != 0,
            configRevision: statement.int(4))
    }

    public func roots() throws -> [MonitoredRoot] {
        let statement = try database.prepare("SELECT * FROM monitored_roots ORDER BY canonical_path;")
        var result: [MonitoredRoot] = []
        while try statement.step() {
            result.append(
                MonitoredRoot(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    canonicalPath: statement.text(1),
                    volumeID: statement.optionalText(2),
                    enabled: statement.int64(3) != 0,
                    configRevision: statement.int(4)))
        }
        return result
    }

    public func rootHealth(rootID: UUID) throws -> RootHealth? {
        let statement = try database.prepare("SELECT * FROM root_health WHERE root_id=?;")
        guard try statement.run([.text(rootID.uuidString)]) else { return nil }
        return RootHealth(
            rootID: rootID,
            activeScanID: statement.optionalText(1).flatMap(UUID.init(uuidString:)),
            state: RootState(rawValue: statement.text(2)) ?? .pending,
            lastSuccessAt: statement.optionalDate(3),
            nextRetryAt: statement.optionalDate(4),
            inventoryCoverage: statement.text(6))
    }

    public func setRootHealth(
        rootID: UUID, state: RootState, activeScanID: UUID?, lastSuccessAt: Date?,
        nextRetryAt: Date?, coverage: String
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO root_health
            (root_id, active_scan_id, state, last_success_at, next_retry_at, inventory_coverage)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(root_id) DO UPDATE SET active_scan_id=excluded.active_scan_id,
                state=excluded.state, last_success_at=COALESCE(excluded.last_success_at, root_health.last_success_at),
                next_retry_at=excluded.next_retry_at, inventory_coverage=excluded.inventory_coverage;
            """)
        try statement.run([
            .text(rootID.uuidString), .optionalText(activeScanID?.uuidString),
            .text(state.rawValue), .optionalDate(lastSuccessAt), .optionalDate(nextRetryAt),
            .text(coverage),
        ])
    }

    // MARK: - Scan generations

    public func beginScan(rootID: UUID, startEventID: UInt64?, at date: Date) throws -> UUID {
        let scanID = UUID()
        let statement = try database.prepare(
            """
            INSERT INTO root_scans (id, root_id, started_at, state, entry_count, start_event_id)
            VALUES (?,?,?,'preparing',0,?);
            """)
        try statement.run([
            .text(scanID.uuidString), .text(rootID.uuidString), .date(date),
            .optionalText(startEventID.map(String.init)),
        ])
        // Mark scanning WITHOUT clearing the current active generation.
        try rawExecute(
            """
            INSERT INTO root_health (root_id, state, inventory_coverage) VALUES (?, 'scanning', 'pending')
            ON CONFLICT(root_id) DO UPDATE SET state='scanning';
            """,
            [.text(rootID.uuidString)])
        return scanID
    }

    public func stageInventory(rootID: UUID, scanID: UUID, files: [FileMetadata]) throws -> Int {
        guard !files.isEmpty else { return 0 }
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO file_inventory
            (root_id, scan_id, path, file_identity, kind, logical_bytes, allocated_bytes,
             modified_at, birth_at, observed_at, link_count)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """)
        try database.transaction {
            for file in files {
                statement.reset()
                try statement.run([
                    .text(rootID.uuidString), .text(scanID.uuidString), .text(file.path),
                    .text(file.fileIdentity), .text(file.kind.rawValue),
                    .optionalInt(file.logicalBytes), .optionalInt(file.allocatedBytes),
                    .optionalDate(file.modifiedAt), .optionalDate(file.birthAt),
                    .date(file.observedAt), .int(Int64(file.linkCount)),
                ])
            }
        }
        return files.count
    }

    public func stageDirectorySummaries(scanID: UUID, summaries: [DirectorySize]) throws -> Int {
        guard !summaries.isEmpty else { return 0 }
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO scan_directory_summaries
            (scan_id, path, allocated_bytes, file_count) VALUES (?,?,?,?);
            """)
        try database.transaction {
            for summary in summaries {
                statement.reset()
                try statement.run([
                    .text(scanID.uuidString), .text(summary.path),
                    .optionalInt(summary.allocatedBytes), .int(Int64(summary.fileCount)),
                ])
            }
        }
        return summaries.count
    }

    /// Discards a failed/cancelled preparing generation without touching the
    /// active baseline.
    public func failScan(rootID: UUID, scanID: UUID, reason: String, state: RootState, at date: Date) throws {
        try database.transaction {
            try rawExecute("DELETE FROM file_inventory WHERE scan_id=?;", [.text(scanID.uuidString)])
            try rawExecute(
                "DELETE FROM scan_directory_summaries WHERE scan_id=?;", [.text(scanID.uuidString)])
            try rawExecute(
                "DELETE FROM root_scans WHERE id=?;", [.text(scanID.uuidString)])
        }
        let health = try rootHealth(rootID: rootID)
        try setRootHealth(
            rootID: rootID, state: state, activeScanID: health?.activeScanID,
            lastSuccessAt: nil, nextRetryAt: nil,
            coverage: health?.inventoryCoverage ?? "pending")
        _ = date
    }

    struct InventoryRow {
        let identity: String
        let allocated: Int64?
        let logical: Int64?
        let linkCount: Int
    }

    private func loadInventory(rootID: UUID, scanID: UUID) throws -> [String: InventoryRow] {
        let statement = try database.prepare(
            """
            SELECT path, file_identity, allocated_bytes, logical_bytes, link_count
            FROM file_inventory WHERE root_id=? AND scan_id=?;
            """)
        try statement.bind([.text(rootID.uuidString), .text(scanID.uuidString)])
        var result: [String: InventoryRow] = [:]
        while try statement.step() {
            result[statement.text(0)] = InventoryRow(
                identity: statement.text(1),
                allocated: statement.isNull(2) ? nil : statement.int64(2),
                logical: statement.isNull(3) ? nil : statement.int64(3),
                linkCount: statement.int(4))
        }
        return result
    }

    private func loadDirectorySummaries(scanID: UUID) throws -> [String: Int64] {
        let statement = try database.prepare(
            "SELECT path, allocated_bytes FROM scan_directory_summaries WHERE scan_id=?;")
        try statement.bind([.text(scanID.uuidString)])
        var result: [String: Int64] = [:]
        while try statement.step() {
            result[statement.text(0)] = statement.isNull(1) ? 0 : statement.int64(1)
        }
        return result
    }

    private func scanEndedAt(scanID: UUID) throws -> Date? {
        let statement = try database.prepare("SELECT ended_at FROM root_scans WHERE id=?;")
        guard try statement.run([.text(scanID.uuidString)]) else { return nil }
        return statement.optionalDate(0)
    }

    /// Publishes a completed scan generation: diffs against the previous active
    /// generation, writes concrete file changes and directory deltas, flips the
    /// active generation, and reclaims the old inventory. UI never sees a partial
    /// generation because the flip is one short transaction.
    public func publishScan(
        rootID: UUID, scanID: UUID, at date: Date, complete: Bool
    ) throws -> PublishResult {
        if !complete {
            try failScan(
                rootID: rootID, scanID: scanID, reason: "incomplete", state: .needsRebaseline,
                at: date)
            return PublishResult(state: .needsRebaseline, fileChanges: [], directoryDeltas: [])
        }

        let health = try rootHealth(rootID: rootID)
        let entryCount = try count(
            "SELECT COUNT(*) FROM file_inventory WHERE scan_id=?;", [.text(scanID.uuidString)])

        guard let previous = health?.activeScanID else {
            // First complete scan: establish the baseline, emit nothing.
            try database.transaction {
                try rawExecute(
                    "UPDATE root_scans SET state='completed', ended_at=?, entry_count=? WHERE id=?;",
                    [.date(date), .int(Int64(entryCount)), .text(scanID.uuidString)])
                try setRootHealth(
                    rootID: rootID, state: .ready, activeScanID: scanID, lastSuccessAt: date,
                    nextRetryAt: nil, coverage: "complete")
            }
            return PublishResult(state: .baseline, fileChanges: [], directoryDeltas: [])
        }

        let before = try loadInventory(rootID: rootID, scanID: previous)
        let after = try loadInventory(rootID: rootID, scanID: scanID)
        let windowStart = try scanEndedAt(scanID: previous) ?? date
        var changes = Self.diff(
            before: before, after: after, rootID: rootID, scanID: scanID,
            windowStart: windowStart, windowEnd: date, observedAt: date)
        changes = Self.mergeMoves(changes)

        let beforeSummaries = try loadDirectorySummaries(scanID: previous)
        let afterSummaries = try loadDirectorySummaries(scanID: scanID)
        var deltas: [DirectoryDelta] = []
        for path in Set(beforeSummaries.keys).union(afterSummaries.keys) {
            let old = beforeSummaries[path] ?? 0
            let new = afterSummaries[path] ?? 0
            guard new - old != 0 else { continue }
            deltas.append(
                DirectoryDelta(
                    pathID: path, windowStart: windowStart, windowEnd: date,
                    deltaAllocatedBytes: new - old, beforeAllocatedBytes: old,
                    afterAllocatedBytes: new, checkpointID: 0, calibration: .calibrated))
        }

        try database.transaction {
            for change in changes { try insertFileChange(change) }
            for delta in deltas { try insert(delta) }
            try rawExecute(
                "UPDATE root_scans SET state='completed', ended_at=?, entry_count=? WHERE id=?;",
                [.date(date), .int(Int64(entryCount)), .text(scanID.uuidString)])
            // Reclaim the previous generation (active + at most one preparing).
            try rawExecute(
                "DELETE FROM file_inventory WHERE root_id=? AND scan_id<>?;",
                [.text(rootID.uuidString), .text(scanID.uuidString)])
            try rawExecute(
                "DELETE FROM scan_directory_summaries WHERE scan_id<>?;",
                [.text(scanID.uuidString)])
            try setRootHealth(
                rootID: rootID, state: .ready, activeScanID: scanID, lastSuccessAt: date,
                nextRetryAt: nil, coverage: "complete")
        }
        return PublishResult(state: .completed, fileChanges: changes, directoryDeltas: deltas)
    }

    // MARK: - Diff rules (§9.1)

    static func diff(
        before: [String: InventoryRow], after: [String: InventoryRow], rootID: UUID,
        scanID: UUID, windowStart: Date, windowEnd: Date, observedAt: Date
    ) -> [FileChange] {
        var result: [FileChange] = []
        for path in Set(before.keys).union(after.keys) {
            let b = before[path]
            let a = after[path]
            let id: UUID
            let kind: FileChangeKind
            let beforeAllocated = b?.allocated
            let afterAllocated = a?.allocated
            let beforeLogical = b?.logical
            let afterLogical = a?.logical
            var delta: Int64?

            if let a, b == nil {
                kind = .added
                delta = a.allocated
            } else if let b, a == nil {
                kind = .removed
                delta = b.allocated.map { -$0 }
            } else if let b, let a {
                if b.identity == a.identity {
                    let oldBytes = b.allocated ?? 0
                    let newBytes = a.allocated ?? 0
                    if newBytes > oldBytes {
                        kind = .grown
                    } else if newBytes < oldBytes {
                        kind = .shrunk
                    } else if a.logical != b.logical {
                        kind = .metadataOnly
                    } else {
                        continue
                    }
                    if b.allocated != nil, a.allocated != nil {
                        delta = newBytes - oldBytes
                    }
                } else {
                    kind = .replaced
                    if b.allocated != nil, a.allocated != nil {
                        delta = (a.allocated ?? 0) - (b.allocated ?? 0)
                    }
                }
            } else {
                continue
            }

            id = FileChange.stableID(
                evidenceVersion: EvidenceVersion.current, rootID: rootID,
                identityBefore: b?.identity, identityAfter: a?.identity,
                pathBefore: path, pathAfter: path, locator: scanID.uuidString)
            result.append(
                FileChange(
                    id: id, rootID: rootID, scanID: scanID, pathBefore: path, pathAfter: path,
                    identityBefore: b?.identity, identityAfter: a?.identity, kind: kind,
                    windowStart: windowStart, windowEnd: windowEnd, observedAt: observedAt,
                    beforeLogical: beforeLogical, afterLogical: afterLogical,
                    beforeAllocated: beforeAllocated, afterAllocated: afterAllocated,
                    deltaAllocated: delta,
                    measurement: (beforeAllocated == nil && kind != .added) ? .beforeUnknown : .measured,
                    timing: .scanWindow, evidenceVersion: EvidenceVersion.current))
        }
        return result
    }

    /// Recognises a same-identity, single-link rename as one `moved` change
    /// instead of an unrelated add + remove.
    static func mergeMoves(_ changes: [FileChange]) -> [FileChange] {
        var added: [String: FileChange] = [:]
        for change in changes where change.kind == .added {
            if let identity = change.identityAfter { added[identity] = change }
        }
        var consumed = Set<UUID>()
        var moves: [FileChange] = []
        for change in changes where change.kind == .removed {
            guard let identity = change.identityBefore, let counterpart = added[identity] else {
                continue
            }
            consumed.insert(change.id)
            consumed.insert(counterpart.id)
            moves.append(
                FileChange(
                    id: FileChange.stableID(
                        evidenceVersion: change.evidenceVersion, rootID: change.rootID,
                        identityBefore: change.identityBefore, identityAfter: counterpart.identityAfter,
                        pathBefore: change.pathBefore, pathAfter: counterpart.pathAfter,
                        locator: change.scanID?.uuidString ?? "move"),
                    rootID: change.rootID, scanID: change.scanID,
                    pathBefore: change.pathBefore, pathAfter: counterpart.pathAfter,
                    identityBefore: change.identityBefore, identityAfter: counterpart.identityAfter,
                    kind: .moved, windowStart: change.windowStart, windowEnd: change.windowEnd,
                    observedAt: change.observedAt, beforeLogical: change.beforeLogical,
                    afterLogical: counterpart.afterLogical, beforeAllocated: change.beforeAllocated,
                    afterAllocated: counterpart.afterAllocated, deltaAllocated: 0,
                    measurement: .measured, timing: .scanWindow,
                    evidenceVersion: change.evidenceVersion))
        }
        return changes.filter { !consumed.contains($0.id) } + moves
    }

    // MARK: - File change queries

    public func fileChange(id: UUID) throws -> FileChange? {
        let statement = try database.prepare("SELECT * FROM file_changes WHERE id=?;")
        guard try statement.run([.text(id.uuidString)]) else { return nil }
        return fileChange(statement)
    }

    public func fileChanges(
        rootID: UUID?, from: Date, to: Date, limit: Int
    ) throws -> [FileChange] {
        let sql =
            rootID == nil
            ? """
            SELECT * FROM file_changes WHERE observed_at>=? AND observed_at<=?
            ORDER BY observed_at DESC, id LIMIT ?;
            """
            : """
            SELECT * FROM file_changes WHERE root_id=? AND observed_at>=? AND observed_at<=?
            ORDER BY observed_at DESC, id LIMIT ?;
            """
        let statement = try database.prepare(sql)
        if let rootID {
            try statement.bind([
                .text(rootID.uuidString), .date(from), .date(to), .int(Int64(limit)),
            ])
        } else {
            try statement.bind([.date(from), .date(to), .int(Int64(limit))])
        }
        var result: [FileChange] = []
        while try statement.step() { result.append(fileChange(statement)) }
        return result
    }

    func insertFileChange(_ change: FileChange) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO file_changes
            (id, root_id, scan_id, path_before, path_after, identity_before, identity_after,
             change_kind, window_start, window_end, observed_at, before_logical, after_logical,
             before_allocated, after_allocated, delta_allocated, measurement_state,
             timing_precision, evidence_version)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(change.id.uuidString), .text(change.rootID.uuidString),
            .optionalText(change.scanID?.uuidString), .optionalText(change.pathBefore),
            .optionalText(change.pathAfter), .optionalText(change.identityBefore),
            .optionalText(change.identityAfter), .text(change.kind.rawValue),
            .date(change.windowStart), .date(change.windowEnd), .date(change.observedAt),
            .optionalInt(change.beforeLogical), .optionalInt(change.afterLogical),
            .optionalInt(change.beforeAllocated), .optionalInt(change.afterAllocated),
            .optionalInt(change.deltaAllocated), .text(change.measurement.rawValue),
            .text(change.timing.rawValue), .int(Int64(change.evidenceVersion)),
        ])
    }

    func fileChange(_ s: SQLiteStatement) -> FileChange {
        FileChange(
            id: UUID(uuidString: s.text(0)) ?? UUID(),
            rootID: UUID(uuidString: s.text(1)) ?? UUID(),
            scanID: s.optionalText(2).flatMap(UUID.init(uuidString:)),
            pathBefore: s.optionalText(3), pathAfter: s.optionalText(4),
            identityBefore: s.optionalText(5), identityAfter: s.optionalText(6),
            kind: FileChangeKind(rawValue: s.text(7)) ?? .metadataOnly,
            windowStart: s.date(8), windowEnd: s.date(9), observedAt: s.date(10),
            beforeLogical: s.isNull(11) ? nil : s.int64(11),
            afterLogical: s.isNull(12) ? nil : s.int64(12),
            beforeAllocated: s.isNull(13) ? nil : s.int64(13),
            afterAllocated: s.isNull(14) ? nil : s.int64(14),
            deltaAllocated: s.isNull(15) ? nil : s.int64(15),
            measurement: MeasurementState(rawValue: s.text(16)) ?? .measured,
            timing: TimingPrecision(rawValue: s.text(17)) ?? .scanWindow,
            evidenceVersion: s.int(18))
    }

    // MARK: - Durable change hints

    @discardableResult
    public func persistHints(
        rootID: UUID, volumeID: String, eventID: UInt64, hints: [ChangeHint],
        checkpoint: UInt64, volumeIdentity: String, at date: Date
    ) throws -> Int {
        guard !hints.isEmpty else { return 0 }
        let statement = try database.prepare(
            """
            INSERT OR IGNORE INTO change_hints
            (id, root_id, volume_id, event_id, path, flags, first_observed_at,
             last_observed_at, replayed, processing_state)
            VALUES (?,?,?,?,?,?,?,?,0,'pending');
            """)
        try database.transaction {
            for hint in hints {
                statement.reset()
                try statement.run([
                    .text(hint.id.uuidString), .text(rootID.uuidString), .text(volumeID),
                    .text(String(hint.eventID)), .text(hint.path),
                    .int(Int64(hint.rawFlags)), .date(hint.observedAt),
                    .date(hint.observedAt),
                ])
            }
            try rawExecute(
                """
                INSERT INTO event_checkpoints (volume_id, stream_kind, volume_identity, last_durable_event_id, updated_at)
                VALUES (?, 'host', ?, ?, ?)
                ON CONFLICT(volume_id) DO UPDATE SET last_durable_event_id=excluded.last_durable_event_id,
                    volume_identity=excluded.volume_identity, updated_at=excluded.updated_at;
                """,
                [.text(volumeID), .text(volumeIdentity), .text(String(checkpoint)), .date(date)])
        }
        return hints.count
    }

    public func pendingHintCount() throws -> Int {
        try count("SELECT COUNT(*) FROM change_hints WHERE processing_state='pending';")
    }

    public func markAllHintsProcessed() throws {
        try rawExecute("UPDATE change_hints SET processing_state='processed';")
    }
}
