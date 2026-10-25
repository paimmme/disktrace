import Foundation

extension DiskTraceStore {
    public struct PathWorkItem: Sendable {
        public let rootID: UUID
        public let path: String
        public let workKind: String
        public let firstDirtyAt: Date
    }

    /// Enqueues probe work for coalesced hint paths (same transaction as hints).
    /// Backfills `pending_path_work` for hints persisted before the path-work pipeline existed.
    public func backfillPathWorkFromPendingHints(limit: Int, now: Date) throws -> Int {
        let statement = try database.prepare(
            """
            SELECT DISTINCT root_id, path FROM change_hints
            WHERE processing_state='pending'
            AND NOT EXISTS (
              SELECT 1 FROM pending_path_work w
              WHERE w.root_id=change_hints.root_id AND w.path=change_hints.path AND w.work_kind='probe')
            LIMIT ?;
            """)
        try statement.bind([.int(Int64(limit))])
        var queued = 0
        var byRoot: [UUID: [String]] = [:]
        while try statement.step() {
            let root = UUID(uuidString: statement.text(0)) ?? UUID()
            byRoot[root, default: []].append(statement.text(1))
        }
        for (rootID, paths) in byRoot {
            try enqueuePathWork(rootID: rootID, paths: paths, now: now)
            queued += paths.count
        }
        return queued
    }

    /// Caller must not hold an outer SQLite transaction (nested transactions are rejected).
    func enqueuePathWork(rootID: UUID, paths: [String], now: Date) throws {
        let coalesced = PathHintProcessor.coalescePaths(paths)
        guard !coalesced.isEmpty else { return }
        let statement = try database.prepare(
            """
            INSERT INTO pending_path_work
            (root_id, path, work_kind, first_dirty_at, last_dirty_at, next_attempt_at, attempt_count)
            VALUES (?,?,'probe',?,?,?,0)
            ON CONFLICT(root_id, path, work_kind) DO UPDATE SET
                last_dirty_at=excluded.last_dirty_at,
                next_attempt_at=MIN(pending_path_work.next_attempt_at, excluded.next_attempt_at);
            """)
        for path in coalesced {
            statement.reset()
            try statement.run([
                .text(rootID.uuidString), .text(path), .date(now), .date(now), .date(now),
            ])
        }
    }

    public func duePathWork(limit: Int, now: Date) throws -> [PathWorkItem] {
        let statement = try database.prepare(
            """
            SELECT root_id, path, work_kind, first_dirty_at FROM pending_path_work
            WHERE next_attempt_at <= ? ORDER BY last_dirty_at ASC LIMIT ?;
            """)
        try statement.bind([.date(now), .int(Int64(limit))])
        var result: [PathWorkItem] = []
        while try statement.step() {
            result.append(
                PathWorkItem(
                    rootID: UUID(uuidString: statement.text(0)) ?? UUID(),
                    path: statement.text(1), workKind: statement.text(2),
                    firstDirtyAt: statement.date(3)))
        }
        return result
    }

    func completePathWork(rootID: UUID, path: String, workKind: String = "probe") throws {
        try rawExecute(
            "DELETE FROM pending_path_work WHERE root_id=? AND path=? AND work_kind=?;",
            [.text(rootID.uuidString), .text(path), .text(workKind)])
    }

    func deferPathWork(rootID: UUID, path: String, workKind: String, attempt: Int, now: Date) throws {
        let delays: [TimeInterval] = [5, 30, 300, 1_800]
        let delay = delays[min(attempt, delays.count - 1)]
        try rawExecute(
            """
            UPDATE pending_path_work SET attempt_count=attempt_count+1, next_attempt_at=?
            WHERE root_id=? AND path=? AND work_kind=?;
            """,
            [.date(now.addingTimeInterval(delay)), .text(rootID.uuidString), .text(path), .text(workKind)])
    }

    public func inventoryFile(rootID: UUID, path: String) throws -> FileMetadata? {
        guard let health = try rootHealth(rootID: rootID), let scanID = health.activeScanID else {
            return nil
        }
        let statement = try database.prepare(
            """
            SELECT path, file_identity, kind, logical_bytes, allocated_bytes,
                   modified_at, birth_at, observed_at, link_count
            FROM file_inventory WHERE root_id=? AND scan_id=? AND path=?;
            """)
        guard try statement.run([
            .text(rootID.uuidString), .text(scanID.uuidString), .text(path),
        ]) else { return nil }
        return FileMetadata(
            path: statement.text(0), fileIdentity: statement.text(1),
            kind: FileKind(rawValue: statement.text(2)) ?? .other,
            logicalBytes: statement.isNull(3) ? nil : statement.int64(3),
            allocatedBytes: statement.isNull(4) ? nil : statement.int64(4),
            modifiedAt: statement.optionalDate(5), birthAt: statement.optionalDate(6),
            observedAt: statement.date(7), linkCount: statement.int(8))
    }

    func upsertInventoryFile(rootID: UUID, scanID: UUID, file: FileMetadata) throws {
        inventoryBudgetCache = nil
        try rawExecute(
            """
            INSERT OR REPLACE INTO file_inventory
            (root_id, scan_id, path, file_identity, kind, logical_bytes, allocated_bytes,
             modified_at, birth_at, observed_at, link_count)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """,
            [
                .text(rootID.uuidString), .text(scanID.uuidString), .text(file.path),
                .text(file.fileIdentity), .text(file.kind.rawValue),
                .optionalInt(file.logicalBytes), .optionalInt(file.allocatedBytes),
                .optionalDate(file.modifiedAt), .optionalDate(file.birthAt),
                .date(file.observedAt), .int(Int64(file.linkCount)),
            ])
    }

    func deleteInventoryFile(rootID: UUID, scanID: UUID, path: String) throws {
        inventoryBudgetCache = nil
        try rawExecute(
            "DELETE FROM file_inventory WHERE root_id=? AND scan_id=? AND path=?;",
            [.text(rootID.uuidString), .text(scanID.uuidString), .text(path)])
    }

    func markHintsProcessed(rootID: UUID, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        for path in paths {
            try rawExecute(
                """
                UPDATE change_hints SET processing_state='processed'
                WHERE root_id=? AND path=? AND processing_state='pending';
                """,
                [.text(rootID.uuidString), .text(path)])
        }
    }

    public func insert(_ sample: SwapSample) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO swap_samples (id, observed_at, swap_used_bytes, swap_file_bytes, note)
            VALUES (?,?,?,?,?);
            """)
        try statement.run([
            .text(sample.id.uuidString), .date(sample.observedAt),
            .optionalInt(sample.swapUsedBytes), .optionalInt(sample.swapFileBytes), .text(sample.note),
        ])
    }

    public func swapSamples(from: Date, to: Date) throws -> [SwapSample] {
        let statement = try database.prepare(
            """
            SELECT id, observed_at, swap_used_bytes, swap_file_bytes, note FROM swap_samples
            WHERE observed_at >= ? AND observed_at <= ? ORDER BY observed_at;
            """)
        try statement.bind([.date(from), .date(to)])
        var result: [SwapSample] = []
        while try statement.step() {
            result.append(
                SwapSample(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    observedAt: statement.date(1),
                    swapUsedBytes: statement.isNull(2) ? nil : statement.int64(2),
                    swapFileBytes: statement.isNull(3) ? nil : statement.int64(3),
                    note: statement.text(4)))
        }
        return result
    }

    public func volumeMethods(for samples: [VolumeSample]) throws -> [UUID: VolumeMethod] {
        guard !samples.isEmpty else { return [:] }
        var map: [UUID: VolumeMethod] = [:]
        let statement = try database.prepare(
            "SELECT sample_id, method FROM volume_measurement_context WHERE sample_id=?;")
        for sample in samples {
            statement.reset()
            guard try statement.run([.text(sample.id.uuidString)]) else { continue }
            if let method = VolumeMethod(rawValue: statement.text(1)) { map[sample.id] = method }
        }
        return map
    }

    public func insertVolumeContext(
        sampleID: UUID, method: VolumeMethod, statfsFree: Int64?, importantFree: Int64?,
        containerIdentity: String?
    ) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO volume_measurement_context
            (sample_id, method, statfs_free_bytes, important_usage_free_bytes, container_identity)
            VALUES (?,?,?,?,?);
            """)
        try statement.run([
            .text(sampleID.uuidString), .text(method.rawValue),
            .optionalInt(statfsFree), .optionalInt(importantFree), .optionalText(containerIdentity),
        ])
    }
}
