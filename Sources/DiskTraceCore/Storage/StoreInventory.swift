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

    /// Updates only the health state, preserving the active generation and the
    /// last success time (used by the low-space state machine).
    public func markRootState(rootID: UUID, state: RootState, coverage: String? = nil) throws {
        try rawExecute(
            """
            INSERT INTO root_health (root_id, state, inventory_coverage) VALUES (?, ?, ?)
            ON CONFLICT(root_id) DO UPDATE SET state=excluded.state,
                inventory_coverage=COALESCE(excluded.inventory_coverage, root_health.inventory_coverage);
            """,
            [.text(rootID.uuidString), .text(state.rawValue), .text(coverage ?? "pending")])
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
        inventoryBudgetCache = nil
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
        inventoryBudgetCache = nil
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
        inventoryBudgetCache = nil
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

    /// One row of the before/after inventory diff. `oldId` is nil for a pure
    /// addition; `newId` is nil for a pure removal.
    struct DiffRow {
        let path: String
        let oldId: String?
        let newId: String?
        let oldAllocated: Int64?
        let newAllocated: Int64?
        let oldLogical: Int64?
        let newLogical: Int64?
        let oldLink: Int?
        let newLink: Int?
    }

    /// Streams the diff between two inventory generations through the
    /// `(root_id, scan_id, path)` primary-key index. It never builds two
    /// in-memory dictionaries of the whole tree: SQLite walks `new` and probes
    /// `old` (and vice versa) one row at a time, so app-layer memory is bounded
    /// by the change set, not the file count. `UNION ALL` + `LEFT JOIN` is used
    /// (not `FULL OUTER JOIN`) for compatibility with the system SQLite.
    func forEachDiffRow(
        rootID: UUID, previous: UUID, current: UUID, _ body: (DiffRow) throws -> Void
    ) throws {
        let statement = try database.prepare(
            """
            SELECT n.path, o.file_identity, n.file_identity,
                   o.allocated_bytes, n.allocated_bytes,
                   o.logical_bytes, n.logical_bytes,
                   o.link_count, n.link_count
            FROM file_inventory AS n
            LEFT JOIN file_inventory AS o
              ON o.root_id=n.root_id AND o.scan_id=? AND o.path=n.path
            WHERE n.root_id=? AND n.scan_id=?
            UNION ALL
            SELECT o.path, o.file_identity, NULL,
                   o.allocated_bytes, NULL,
                   o.logical_bytes, NULL,
                   o.link_count, NULL
            FROM file_inventory AS o
            LEFT JOIN file_inventory AS n
              ON n.root_id=o.root_id AND n.scan_id=? AND n.path=o.path
            WHERE o.root_id=? AND o.scan_id=? AND n.path IS NULL;
            """)
        try statement.bind([
            .text(previous.uuidString), .text(rootID.uuidString), .text(current.uuidString),
            .text(current.uuidString), .text(rootID.uuidString), .text(previous.uuidString),
        ])
        while try statement.step() {
            try body(
                DiffRow(
                    path: statement.text(0),
                    oldId: statement.optionalText(1),
                    newId: statement.optionalText(2),
                    oldAllocated: statement.isNull(3) ? nil : statement.int64(3),
                    newAllocated: statement.isNull(4) ? nil : statement.int64(4),
                    oldLogical: statement.isNull(5) ? nil : statement.int64(5),
                    newLogical: statement.isNull(6) ? nil : statement.int64(6),
                    oldLink: statement.isNull(7) ? nil : statement.int(7),
                    newLink: statement.isNull(8) ? nil : statement.int(8)))
        }
    }

    private func loadDirectorySummaries(scanID: UUID) throws -> [String: Int64] {
        try directorySummaries(scanID: scanID)
    }

    /// Root-scoped directory summaries for one scan generation (public for tests).
    public func directorySummaries(scanID: UUID) throws -> [String: Int64] {
        let statement = try database.prepare(
            "SELECT path, allocated_bytes FROM scan_directory_summaries WHERE scan_id=?;")
        try statement.bind([.text(scanID.uuidString)])
        var result: [String: Int64] = [:]
        while try statement.step() {
            result[statement.text(0)] = statement.isNull(1) ? 0 : statement.int64(1)
        }
        return result
    }

    /// The root that owns a scan generation, or nil if the row is gone.
    public func scanOwner(scanID: UUID) throws -> UUID? {
        let statement = try database.prepare("SELECT root_id FROM root_scans WHERE id=?;")
        guard try statement.run([.text(scanID.uuidString)]) else { return nil }
        return UUID(uuidString: statement.text(0))
    }

    public func inventoryCount(rootID: UUID, scanID: UUID) throws -> Int {
        try count(
            "SELECT COUNT(*) FROM file_inventory WHERE root_id=? AND scan_id=?;",
            [.text(rootID.uuidString), .text(scanID.uuidString)])
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
        rootID: UUID, scanID: UUID, at date: Date, complete: Bool,
        timing: TimingPrecision = .scanWindow, sizeComplete: Bool = true
    ) throws -> PublishResult {
        inventoryBudgetCache = nil
        if !complete {
            try failScan(
                rootID: rootID, scanID: scanID, reason: "incomplete", state: .needsRebaseline,
                at: date)
            return PublishResult(state: .needsRebaseline, fileChanges: [], directoryDeltas: [])
        }

        let health = try rootHealth(rootID: rootID)
        let entryCount = try count(
            "SELECT COUNT(*) FROM file_inventory WHERE scan_id=?;", [.text(scanID.uuidString)])

        // Only trust a previous generation that actually belongs to this root.
        // A corrupt or mis-referenced health row must not let us diff/delete
        // across roots.
        var previousScanID = health?.activeScanID
        if let previous = previousScanID, try scanOwner(scanID: previous) != rootID {
            previousScanID = nil
        }

        guard let previous = previousScanID else {
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

        let windowStart = try scanEndedAt(scanID: previous) ?? date

        let beforeSummaries = try directorySummaries(scanID: previous)
        let afterSummaries = try directorySummaries(scanID: scanID)
        var deltas: [DirectoryDelta] = []
        for path in Set(beforeSummaries.keys).union(afterSummaries.keys) {
            let old = beforeSummaries[path] ?? 0
            let new = afterSummaries[path] ?? 0
            guard new - old != 0 else { continue }
            deltas.append(
                DirectoryDelta(
                    pathID: path, windowStart: windowStart, windowEnd: date,
                    deltaAllocatedBytes: new - old, beforeAllocatedBytes: old,
                    afterAllocatedBytes: new, checkpointID: 0,
                    calibration: sizeComplete ? .calibrated : .coverageGap))
        }

        var emitted: [FileChange] = []
        try database.transaction {
            // Stream the diff. Same-path content changes are written immediately
            // in batches; pure additions/removals are held only by identity
            // (bounded by the change set) so a same-identity rename can be
            // recognised as one `moved` record.
            var batch: [FileChange] = []
            var addedByIdentity: [String: [FileChange]] = [:]
            var removedByIdentity: [String: [FileChange]] = [:]
            var addedLinks: [String: Int] = [:]
            var removedLinks: [String: Int] = [:]

            try forEachDiffRow(rootID: rootID, previous: previous, current: scanID) { row in
                if let newId = row.newId, row.oldId == nil {
                    let change = Self.change(
                        path: row.path, pathAfter: row.path, identityBefore: nil, identityAfter: newId,
                        kind: .added, before: nil, after: row.newAllocated, beforeLogical: nil,
                        afterLogical: row.newLogical, delta: row.newAllocated, rootID: rootID,
                        scanID: scanID, windowStart: windowStart, windowEnd: date, observedAt: date,
                        timing: timing)
                    addedByIdentity[newId, default: []].append(change)
                    addedLinks[newId] = row.newLink ?? 1
                } else if let oldId = row.oldId, row.newId == nil {
                    let change = Self.change(
                        path: row.path, pathAfter: row.path, identityBefore: oldId, identityAfter: nil,
                        kind: .removed, before: row.oldAllocated, after: nil,
                        beforeLogical: row.oldLogical, afterLogical: nil,
                        delta: row.oldAllocated.map { -$0 }, rootID: rootID, scanID: scanID,
                        windowStart: windowStart, windowEnd: date, observedAt: date, timing: timing)
                    removedByIdentity[oldId, default: []].append(change)
                    removedLinks[oldId] = row.oldLink ?? 1
                } else if row.oldId != nil, row.newId != nil {
                    guard let change = Self.changedRow(
                        row: row, rootID: rootID, scanID: scanID, windowStart: windowStart,
                        windowEnd: date, observedAt: date, timing: timing)
                    else { return }
                    batch.append(change)
                    if batch.count >= 500 {
                        for item in batch { try insertFileChange(item) }
                        emitted.append(contentsOf: batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !batch.isEmpty {
                for item in batch { try insertFileChange(item) }
                emitted.append(contentsOf: batch)
            }

            // Same identity, one occurrence each side, no hardlinks → moved.
            var movedIdentities = Set<String>()
            var moves: [FileChange] = []
            for (identity, removed) in removedByIdentity where removed.count == 1 {
                guard let added = addedByIdentity[identity], added.count == 1 else { continue }
                guard (removedLinks[identity] ?? 1) <= 1, (addedLinks[identity] ?? 1) <= 1 else {
                    continue
                }
                moves.append(Self.moved(removed: removed[0], added: added[0], timing: timing))
                movedIdentities.insert(identity)
            }
            var tail: [FileChange] = []
            for (identity, list) in addedByIdentity where !movedIdentities.contains(identity) {
                tail.append(contentsOf: list)
            }
            for (identity, list) in removedByIdentity where !movedIdentities.contains(identity) {
                tail.append(contentsOf: list)
            }
            tail.append(contentsOf: moves)
            for change in tail { try insertFileChange(change) }
            emitted.append(contentsOf: tail)

            for delta in deltas { try insert(delta) }
            try rawExecute(
                "UPDATE root_scans SET state='completed', ended_at=?, entry_count=? WHERE id=?;",
                [.date(date), .int(Int64(entryCount)), .text(scanID.uuidString)])
            // Reclaim the previous generation (active + at most one preparing).
            // Both deletes are root-scoped: a scan of root B must never remove
            // root A's inventory or directory summaries.
            try rawExecute(
                "DELETE FROM file_inventory WHERE root_id=? AND scan_id<>?;",
                [.text(rootID.uuidString), .text(scanID.uuidString)])
            try rawExecute(
                """
                DELETE FROM scan_directory_summaries
                WHERE scan_id IN (SELECT id FROM root_scans WHERE root_id=? AND id<>?);
                """,
                [.text(rootID.uuidString), .text(scanID.uuidString)])
            try setRootHealth(
                rootID: rootID, state: .ready, activeScanID: scanID, lastSuccessAt: date,
                nextRetryAt: nil, coverage: "complete")
        }
        return PublishResult(state: .completed, fileChanges: emitted, directoryDeltas: deltas)
    }

    // MARK: - Diff row → FileChange

    private static func change(
        path: String, pathAfter: String, identityBefore: String?, identityAfter: String?,
        kind: FileChangeKind, before: Int64?, after: Int64?, beforeLogical: Int64?,
        afterLogical: Int64?, delta: Int64?, rootID: UUID, scanID: UUID, windowStart: Date,
        windowEnd: Date, observedAt: Date, timing: TimingPrecision,
        locator: String? = nil
    ) -> FileChange {
        FileChange(
            id: FileChange.stableID(
                evidenceVersion: EvidenceVersion.current, rootID: rootID,
                identityBefore: identityBefore, identityAfter: identityAfter, pathBefore: path,
                pathAfter: pathAfter, locator: locator ?? scanID.uuidString),
            rootID: rootID, scanID: scanID, pathBefore: path, pathAfter: pathAfter,
            identityBefore: identityBefore, identityAfter: identityAfter, kind: kind,
            windowStart: windowStart, windowEnd: windowEnd, observedAt: observedAt,
            beforeLogical: beforeLogical, afterLogical: afterLogical, beforeAllocated: before,
            afterAllocated: after, deltaAllocated: delta,
            measurement: (kind != .added && before == nil) ? .beforeUnknown : .measured,
            timing: timing, evidenceVersion: EvidenceVersion.current)
    }

    private static func changedRow(
        row: DiffRow, rootID: UUID, scanID: UUID, windowStart: Date, windowEnd: Date,
        observedAt: Date, timing: TimingPrecision
    ) -> FileChange? {
        guard let oldId = row.oldId, let newId = row.newId else { return nil }
        let oldBytes = row.oldAllocated
        let newBytes = row.newAllocated
        let kind: FileChangeKind
        var delta: Int64?
        if oldId == newId {
            if let o = oldBytes, let n = newBytes {
                if n > o { kind = .grown } else if n < o { kind = .shrunk } else if row.newLogical != row.oldLogical {
                    kind = .metadataOnly
                } else { return nil }
                delta = n - o
            } else {
                if row.newLogical == row.oldLogical { return nil }
                kind = .metadataOnly
            }
        } else {
            kind = .replaced
            if let o = oldBytes, let n = newBytes { delta = n - o }
        }
        return change(
            path: row.path, pathAfter: row.path, identityBefore: oldId, identityAfter: newId,
            kind: kind, before: oldBytes, after: newBytes, beforeLogical: row.oldLogical,
            afterLogical: row.newLogical, delta: delta, rootID: rootID, scanID: scanID,
            windowStart: windowStart, windowEnd: windowEnd, observedAt: observedAt, timing: timing)
    }

    private static func moved(removed: FileChange, added: FileChange, timing: TimingPrecision) -> FileChange {
        FileChange(
            id: FileChange.stableID(
                evidenceVersion: removed.evidenceVersion, rootID: removed.rootID,
                identityBefore: removed.identityBefore, identityAfter: added.identityAfter,
                pathBefore: removed.pathBefore, pathAfter: added.pathAfter,
                locator: "move:\(removed.scanID?.uuidString ?? "")"),
            rootID: removed.rootID, scanID: removed.scanID, pathBefore: removed.pathBefore,
            pathAfter: added.pathAfter, identityBefore: removed.identityBefore,
            identityAfter: added.identityAfter, kind: .moved, windowStart: removed.windowStart,
            windowEnd: removed.windowEnd, observedAt: removed.observedAt,
            beforeLogical: removed.beforeLogical, afterLogical: added.afterLogical,
            beforeAllocated: removed.beforeAllocated, afterAllocated: added.afterAllocated,
            deltaAllocated: 0, measurement: .measured, timing: timing,
            evidenceVersion: removed.evidenceVersion)
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
            for hint in hints {
                try rawExecute(
                    """
                    INSERT INTO pending_path_work
                    (root_id, path, work_kind, first_dirty_at, last_dirty_at, next_attempt_at, attempt_count)
                    VALUES (?, ?, 'probe', ?, ?, ?, 0)
                    ON CONFLICT(root_id, path, work_kind) DO UPDATE SET
                        last_dirty_at=excluded.last_dirty_at,
                        next_attempt_at=MIN(pending_path_work.next_attempt_at, excluded.next_attempt_at);
                    """,
                    [
                        .text(rootID.uuidString), .text(hint.path), .date(hint.observedAt),
                        .date(hint.observedAt), .date(date),
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

    public struct PendingPathWork: Sendable {
        public let rootID: UUID
        public let path: String
        public let firstDirtyAt: Date
        public let lastDirtyAt: Date
        public let attemptCount: Int
    }

    public func duePathWork(limit: Int, now: Date) throws -> [PendingPathWork] {
        let statement = try database.prepare(
            """
            SELECT root_id, path, first_dirty_at, last_dirty_at, attempt_count
            FROM pending_path_work
            WHERE work_kind='probe' AND next_attempt_at<=?
            ORDER BY last_dirty_at ASC LIMIT ?;
            """)
        try statement.bind([.date(now), .int(Int64(limit))])
        var result: [PendingPathWork] = []
        while try statement.step() {
            guard let rootID = UUID(uuidString: statement.text(0)) else { continue }
            result.append(
                PendingPathWork(
                    rootID: rootID, path: statement.text(1), firstDirtyAt: statement.date(2),
                    lastDirtyAt: statement.date(3), attemptCount: statement.int(4)))
        }
        return result
    }

    public func finishPathWork(rootID: UUID, path: String) throws {
        try rawExecute(
            "DELETE FROM pending_path_work WHERE root_id=? AND path=? AND work_kind='probe';",
            [.text(rootID.uuidString), .text(path)])
        try rawExecute(
            """
            UPDATE change_hints SET processing_state='processed'
            WHERE root_id=? AND path=? AND processing_state='pending';
            """,
            [.text(rootID.uuidString), .text(path)])
    }

    public func deferPathWork(rootID: UUID, path: String, attemptCount: Int, now: Date) throws {
        let delay: TimeInterval
        switch attemptCount {
        case 0: delay = 5
        case 1: delay = 30
        default: delay = 300
        }
        try rawExecute(
            """
            UPDATE pending_path_work
            SET attempt_count=attempt_count+1, next_attempt_at=?
            WHERE root_id=? AND path=? AND work_kind='probe';
            """,
            [.date(now.addingTimeInterval(delay)), .text(rootID.uuidString), .text(path)])
    }

    /// Probes one path against the active inventory generation and records a
    /// `liveHintWindow` file change when allocation differs.
    public func applyLiveProbe(
        rootID: UUID, metadata: FileMetadata, hintObservedAt: Date, now: Date
    ) throws -> FileChange? {
        guard let health = try rootHealth(rootID: rootID),
            health.state == .ready, let scanID = health.activeScanID
        else { return nil }

        let statement = try database.prepare(
            """
            SELECT file_identity, allocated_bytes, logical_bytes, link_count
            FROM file_inventory WHERE root_id=? AND scan_id=? AND path=?;
            """)
        try statement.bind([
            .text(rootID.uuidString), .text(scanID.uuidString), .text(metadata.path),
        ])
        let hadRow = try statement.step()
        let oldId = hadRow ? statement.optionalText(0) : nil
        let oldAllocated = hadRow && !statement.isNull(1) ? statement.int64(1) : nil
        let oldLogical = hadRow && !statement.isNull(2) ? statement.int64(2) : nil
        let oldLink = hadRow && !statement.isNull(3) ? statement.int(3) : nil

        try upsertInventoryRow(rootID: rootID, scanID: scanID, metadata: metadata)

        let row = DiffRow(
            path: metadata.path, oldId: oldId, newId: metadata.fileIdentity,
            oldAllocated: oldAllocated, newAllocated: metadata.allocatedBytes,
            oldLogical: oldLogical, newLogical: metadata.logicalBytes,
            oldLink: oldLink, newLink: metadata.linkCount)

        let windowStart = hintObservedAt
        let locator = "live:\(metadata.path)|\(Int(hintObservedAt.timeIntervalSince1970))"
        let change: FileChange?
        if oldId == nil {
            change = Self.change(
                path: metadata.path, pathAfter: metadata.path, identityBefore: nil,
                identityAfter: metadata.fileIdentity, kind: .added, before: nil,
                after: metadata.allocatedBytes, beforeLogical: nil,
                afterLogical: metadata.logicalBytes, delta: metadata.allocatedBytes,
                rootID: rootID, scanID: scanID, windowStart: windowStart, windowEnd: now,
                observedAt: now, timing: .liveHintWindow, locator: locator)
        } else {
            guard
                var diff = Self.changedRow(
                    row: row, rootID: rootID, scanID: scanID, windowStart: windowStart,
                    windowEnd: now, observedAt: now, timing: .liveHintWindow)
            else { return nil }
            diff = FileChange(
                id: FileChange.stableID(
                    evidenceVersion: EvidenceVersion.current, rootID: rootID,
                    identityBefore: diff.identityBefore, identityAfter: diff.identityAfter,
                    pathBefore: diff.pathBefore, pathAfter: diff.pathAfter, locator: locator),
                rootID: diff.rootID, scanID: diff.scanID, pathBefore: diff.pathBefore,
                pathAfter: diff.pathAfter, identityBefore: diff.identityBefore,
                identityAfter: diff.identityAfter, kind: diff.kind, windowStart: diff.windowStart,
                windowEnd: diff.windowEnd, observedAt: diff.observedAt,
                beforeLogical: diff.beforeLogical, afterLogical: diff.afterLogical,
                beforeAllocated: diff.beforeAllocated, afterAllocated: diff.afterAllocated,
                deltaAllocated: diff.deltaAllocated, measurement: diff.measurement,
                timing: diff.timing, evidenceVersion: diff.evidenceVersion)
            change = diff
        }
        if let change {
            try insertFileChange(change)
        }
        return change
    }

    public func applyLiveRemoval(
        rootID: UUID, path: String, hintObservedAt: Date, now: Date
    ) throws -> FileChange? {
        guard let health = try rootHealth(rootID: rootID),
            health.state == .ready, let scanID = health.activeScanID
        else { return nil }
        let statement = try database.prepare(
            """
            SELECT file_identity, allocated_bytes, logical_bytes
            FROM file_inventory WHERE root_id=? AND scan_id=? AND path=?;
            """)
        try statement.bind([
            .text(rootID.uuidString), .text(scanID.uuidString), .text(path),
        ])
        guard try statement.step() else { return nil }
        let oldId = statement.text(0)
        let oldAllocated = statement.isNull(1) ? nil : statement.int64(1)
        let oldLogical = statement.isNull(2) ? nil : statement.int64(2)
        try rawExecute(
            "DELETE FROM file_inventory WHERE root_id=? AND scan_id=? AND path=?;",
            [.text(rootID.uuidString), .text(scanID.uuidString), .text(path)])
        inventoryBudgetCache = nil
        let locator = "live:\(path)|\(Int(hintObservedAt.timeIntervalSince1970))"
        let change = Self.change(
            path: path, pathAfter: path, identityBefore: oldId, identityAfter: nil,
            kind: .removed, before: oldAllocated, after: nil, beforeLogical: oldLogical,
            afterLogical: nil, delta: oldAllocated.map { -$0 }, rootID: rootID, scanID: scanID,
            windowStart: hintObservedAt, windowEnd: now, observedAt: now,
            timing: .liveHintWindow, locator: locator)
        try insertFileChange(change)
        return change
    }

    private func upsertInventoryRow(rootID: UUID, scanID: UUID, metadata: FileMetadata) throws {
        try rawExecute(
            """
            INSERT INTO file_inventory
            (root_id, scan_id, path, file_identity, kind, logical_bytes, allocated_bytes,
             modified_at, birth_at, observed_at, link_count)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(root_id, scan_id, path) DO UPDATE SET
                file_identity=excluded.file_identity, kind=excluded.kind,
                logical_bytes=excluded.logical_bytes, allocated_bytes=excluded.allocated_bytes,
                modified_at=excluded.modified_at, birth_at=excluded.birth_at,
                observed_at=excluded.observed_at, link_count=excluded.link_count;
            """,
            [
                .text(rootID.uuidString), .text(scanID.uuidString), .text(metadata.path),
                .text(metadata.fileIdentity), .text(metadata.kind.rawValue),
                .optionalInt(metadata.logicalBytes), .optionalInt(metadata.allocatedBytes),
                .optionalDate(metadata.modifiedAt), .optionalDate(metadata.birthAt),
                .date(metadata.observedAt), .int(Int64(metadata.linkCount)),
            ])
        inventoryBudgetCache = nil
    }

    public func pendingHintCount() throws -> Int {
        try count("SELECT COUNT(*) FROM change_hints WHERE processing_state='pending';")
    }

    public func markAllHintsProcessed() throws {
        try rawExecute("UPDATE change_hints SET processing_state='processed';")
    }

    /// `PRAGMA integrity_check` — "ok" on a healthy database.
    public func integrityCheck() throws -> [String] {
        let statement = try database.prepare("PRAGMA integrity_check;")
        var result: [String] = []
        while try statement.step() { result.append(statement.text(0)) }
        return result
    }

    /// `PRAGMA foreign_key_check` — empty on a healthy database.
    public func foreignKeyViolations() throws -> [String] {
        let statement = try database.prepare("PRAGMA foreign_key_check;")
        var result: [String] = []
        while try statement.step() { result.append(statement.text(0)) }
        return result
    }
}
