import Foundation

/// Versioned, transactional schema migrations. The schema is deliberately small
/// and access-pattern driven rather than fully normalized.
enum Migrations {
    static let currentVersion = 6

    static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER NOT NULL
            );
            """)

        let version = try readVersion(database)
        if version < 1 {
            try database.transaction {
                try database.execute(schemaV1)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (1);")
            }
        }
        if version < 2 {
            try database.transaction {
                try database.execute(schemaV2)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (2);")
            }
        }
        if version < 3 {
            try database.transaction {
                try database.execute(schemaV3)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (3);")
            }
        }
        if version < 4 {
            try database.transaction {
                try database.execute(schemaV4)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (4);")
            }
        }
        if version < 5 {
            try database.transaction {
                try database.execute(schemaV5)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (5);")
            }
        }
        if version < 6 {
            try database.transaction {
                try database.execute(schemaV6)
                try database.execute("DELETE FROM schema_version;")
                try database.execute("INSERT INTO schema_version(version) VALUES (6);")
            }
        }
    }

    /// Refuse to open a database whose schema is newer than this build.
    static func assertWritable(_ database: SQLiteDatabase) throws {
        let version = try readVersion(database)
        if version > currentVersion {
            throw SQLiteError(
                message: "database schema v\(version) is newer than supported v\(currentVersion)",
                code: 0)
        }
    }

    private static func readVersion(_ database: SQLiteDatabase) throws -> Int {
        let exists = try database.prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version';")
        guard try exists.step(), exists.int64(0) > 0 else { return 0 }
        let statement = try database.prepare("SELECT COUNT(*) FROM schema_version;")
        guard try statement.step() else { return 0 }
        if statement.int64(0) == 0 { return 0 }
        let select = try database.prepare("SELECT version FROM schema_version LIMIT 1;")
        guard try select.step() else { return 0 }
        return select.int(0)
    }

    private static let schemaV1 = """
        CREATE TABLE IF NOT EXISTS volume_samples (
            id TEXT PRIMARY KEY,
            volume_id TEXT NOT NULL,
            observed_at REAL NOT NULL,
            free_bytes INTEGER NOT NULL,
            capacity_bytes INTEGER NOT NULL,
            status TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_volume_samples ON volume_samples(volume_id, observed_at);

        CREATE TABLE IF NOT EXISTS directory_changes (
            id TEXT PRIMARY KEY,
            path_id TEXT NOT NULL,
            window_start REAL NOT NULL,
            window_end REAL NOT NULL,
            delta_allocated_bytes INTEGER NOT NULL,
            before_allocated_bytes INTEGER NOT NULL,
            after_allocated_bytes INTEGER NOT NULL,
            checkpoint_id INTEGER NOT NULL,
            calibration TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_directory_changes ON directory_changes(path_id, window_end);

        CREATE TABLE IF NOT EXISTS agent_activities (
            id TEXT PRIMARY KEY,
            session_id_hash TEXT NOT NULL,
            client TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            working_directory TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_activities ON agent_activities(session_id_hash, started_at);

        CREATE TABLE IF NOT EXISTS evidence (
            id TEXT PRIMARY KEY,
            subject_id TEXT NOT NULL,
            source TEXT NOT NULL,
            scope TEXT NOT NULL,
            strength INTEGER NOT NULL,
            identity TEXT,
            observed_at REAL NOT NULL,
            limitation TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_evidence_subject ON evidence(subject_id);

        CREATE TABLE IF NOT EXISTS alert_decisions (
            id TEXT PRIMARY KEY,
            rule_version TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            action TEXT NOT NULL,
            reason TEXT NOT NULL,
            evidence_class TEXT NOT NULL,
            evidence_ids TEXT NOT NULL,
            cooldown_key TEXT,
            evaluated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_alert_decisions ON alert_decisions(subject_id, evaluated_at);

        CREATE TABLE IF NOT EXISTS coverage_gaps (
            id TEXT PRIMARY KEY,
            start_at REAL NOT NULL,
            end_at REAL,
            cause TEXT NOT NULL,
            affected_roots TEXT NOT NULL,
            severity TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS user_rules (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            path_pattern TEXT NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL,
            explanation TEXT NOT NULL,
            is_revoked INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS monitor_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """

    /// v2 — continuous attribution: task identity on activities and per-file
    /// session-log sync cursors. Upgrade is a single versioned transaction.
    private static let schemaV2 = """
        ALTER TABLE agent_activities ADD COLUMN task_id_hash TEXT;
        ALTER TABLE agent_activities ADD COLUMN window_is_task_bounded INTEGER NOT NULL DEFAULT 0;

        CREATE TABLE IF NOT EXISTS session_sync (
            file_path TEXT PRIMARY KEY,
            file_identity TEXT NOT NULL,
            session_id_hash TEXT,
            byte_offset INTEGER NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at REAL,
            last_processed REAL NOT NULL
        );
        """

    /// v3 — persist the normalized working directory alongside the cursor so
    /// session metadata survives a restart (the log prefix is not re-read).
    private static let schemaV3 = """
        ALTER TABLE session_sync ADD COLUMN working_directory TEXT;
        """

    /// v4 — task windows, client verification, and a complete-line cursor with a
    /// persisted discard state. Existing cursors are marked cursor_version=0 so
    /// the syncer can repair them once (no session file is read inside the
    /// migration transaction).
    private static let schemaV4 = """
        ALTER TABLE session_sync ADD COLUMN cursor_version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE session_sync ADD COLUMN discarding_oversized INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE session_sync ADD COLUMN first_event_at REAL;
        ALTER TABLE session_sync ADD COLUMN last_event_at REAL;
        ALTER TABLE session_sync ADD COLUMN last_error TEXT;
        ALTER TABLE session_sync ADD COLUMN retry_after REAL;
        ALTER TABLE session_sync ADD COLUMN last_scheduled_at REAL;

        CREATE TABLE IF NOT EXISTS task_windows (
            activity_id TEXT PRIMARY KEY,
            session_hash TEXT NOT NULL,
            task_hash TEXT NOT NULL,
            client_kind TEXT NOT NULL,
            client_version TEXT,
            lifecycle_state TEXT NOT NULL,
            start_known INTEGER NOT NULL,
            end_known INTEGER NOT NULL,
            last_event_at REAL NOT NULL,
            schema_kind TEXT NOT NULL,
            verification_state TEXT NOT NULL,
            source_log_path TEXT NOT NULL,
            event_start_offset INTEGER,
            event_end_offset INTEGER,
            FOREIGN KEY(activity_id) REFERENCES agent_activities(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_task_windows_session_task ON task_windows(session_hash, task_hash);
        CREATE INDEX IF NOT EXISTS idx_task_windows_recent ON task_windows(last_event_at, lifecycle_state);
        CREATE TABLE IF NOT EXISTS client_verification (
            client_kind TEXT NOT NULL,
            client_version TEXT NOT NULL,
            schema_kind TEXT NOT NULL,
            result TEXT NOT NULL,
            verified_at REAL,
            evidence_reference TEXT,
            PRIMARY KEY(client_kind, client_version, schema_kind)
        );
        """

    /// v5 — scopes, durable change clues, per-generation file inventory and
    /// concrete file changes. Old directory observations gain a nullable scan_id
    /// (NULL = legacy). This never stores a whole historical tree: one active
    /// generation plus at most one preparing generation per root.
    private static let schemaV5 = """
        CREATE TABLE IF NOT EXISTS monitored_roots (
            id TEXT PRIMARY KEY,
            canonical_path TEXT NOT NULL UNIQUE,
            volume_id TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            config_revision INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS root_scans (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            state TEXT NOT NULL,
            entry_count INTEGER NOT NULL DEFAULT 0,
            incomplete_reason TEXT,
            start_event_id TEXT,
            end_event_id TEXT,
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_root_scans_root_time ON root_scans(root_id, started_at);
        CREATE TABLE IF NOT EXISTS root_health (
            root_id TEXT PRIMARY KEY,
            active_scan_id TEXT,
            state TEXT NOT NULL,
            last_success_at REAL,
            next_retry_at REAL,
            open_gap_id TEXT,
            inventory_coverage TEXT NOT NULL DEFAULT 'pending',
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
        );
        CREATE TABLE IF NOT EXISTS change_hints (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            volume_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            path TEXT NOT NULL,
            flags INTEGER NOT NULL,
            first_observed_at REAL NOT NULL,
            last_observed_at REAL NOT NULL,
            replayed INTEGER NOT NULL DEFAULT 0,
            processing_state TEXT NOT NULL,
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
            UNIQUE(volume_id, event_id, path)
        );
        CREATE INDEX IF NOT EXISTS idx_hints_pending ON change_hints(processing_state, first_observed_at);
        CREATE TABLE IF NOT EXISTS event_checkpoints (
            volume_id TEXT PRIMARY KEY,
            stream_kind TEXT NOT NULL,
            volume_identity TEXT NOT NULL,
            last_durable_event_id TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS file_inventory (
            root_id TEXT NOT NULL,
            scan_id TEXT NOT NULL,
            path TEXT NOT NULL,
            file_identity TEXT NOT NULL,
            kind TEXT NOT NULL,
            logical_bytes INTEGER,
            allocated_bytes INTEGER,
            modified_at REAL,
            birth_at REAL,
            observed_at REAL NOT NULL,
            link_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY(root_id, scan_id, path),
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
            FOREIGN KEY(scan_id) REFERENCES root_scans(id)
        );
        CREATE INDEX IF NOT EXISTS idx_inventory_identity ON file_inventory(root_id, scan_id, file_identity);
        CREATE TABLE IF NOT EXISTS file_changes (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            scan_id TEXT,
            path_before TEXT,
            path_after TEXT,
            identity_before TEXT,
            identity_after TEXT,
            change_kind TEXT NOT NULL,
            window_start REAL NOT NULL,
            window_end REAL NOT NULL,
            observed_at REAL NOT NULL,
            before_logical INTEGER,
            after_logical INTEGER,
            before_allocated INTEGER,
            after_allocated INTEGER,
            delta_allocated INTEGER,
            measurement_state TEXT NOT NULL,
            timing_precision TEXT NOT NULL,
            evidence_version INTEGER NOT NULL,
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id),
            FOREIGN KEY(scan_id) REFERENCES root_scans(id)
        );
        CREATE INDEX IF NOT EXISTS idx_file_changes_root_time ON file_changes(root_id, observed_at);
        CREATE INDEX IF NOT EXISTS idx_file_changes_paths ON file_changes(path_after, observed_at);
        CREATE TABLE IF NOT EXISTS pending_path_work (
            root_id TEXT NOT NULL,
            path TEXT NOT NULL,
            work_kind TEXT NOT NULL,
            first_dirty_at REAL NOT NULL,
            last_dirty_at REAL NOT NULL,
            next_attempt_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(root_id, path, work_kind)
        );
        ALTER TABLE directory_changes ADD COLUMN scan_id TEXT;
        CREATE TABLE IF NOT EXISTS scan_directory_summaries (
            scan_id TEXT NOT NULL,
            path TEXT NOT NULL,
            allocated_bytes INTEGER,
            file_count INTEGER NOT NULL,
            PRIMARY KEY(scan_id, path),
            FOREIGN KEY(scan_id) REFERENCES root_scans(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS volume_measurement_context (
            sample_id TEXT PRIMARY KEY,
            method TEXT NOT NULL,
            FOREIGN KEY(sample_id) REFERENCES volume_samples(id) ON DELETE CASCADE
        );
        """

    /// v6 — user-understandable events, task links, presence checks, notification
    /// outbox and command receipts.
    private static let schemaV6 = """
        CREATE TABLE IF NOT EXISTS storage_events (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            scope_path TEXT NOT NULL,
            window_start REAL NOT NULL,
            window_end REAL NOT NULL,
            gross_added_bytes INTEGER,
            gross_removed_bytes INTEGER,
            net_bytes INTEGER,
            measurement_state TEXT NOT NULL,
            reason_category TEXT NOT NULL,
            attribution_class TEXT NOT NULL,
            candidate_count INTEGER NOT NULL DEFAULT 0,
            unassigned_bytes INTEGER,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(root_id) REFERENCES monitored_roots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_storage_events_time ON storage_events(window_end, root_id);
        CREATE TABLE IF NOT EXISTS event_files (
            event_id TEXT NOT NULL,
            change_id TEXT NOT NULL,
            PRIMARY KEY(event_id, change_id),
            FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE,
            FOREIGN KEY(change_id) REFERENCES file_changes(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS task_links (
            event_id TEXT NOT NULL,
            activity_id TEXT NOT NULL,
            link_state TEXT NOT NULL,
            link_basis TEXT NOT NULL,
            candidate_bytes INTEGER,
            algorithm_version TEXT NOT NULL,
            limitation TEXT NOT NULL,
            PRIMARY KEY(event_id, activity_id, algorithm_version),
            FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE,
            FOREIGN KEY(activity_id) REFERENCES agent_activities(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS presence_checks (
            change_id TEXT NOT NULL,
            scheduled_at REAL NOT NULL,
            checked_at REAL,
            result TEXT NOT NULL,
            current_identity TEXT,
            current_allocated INTEGER,
            PRIMARY KEY(change_id, scheduled_at),
            FOREIGN KEY(change_id) REFERENCES file_changes(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS notification_outbox (
            id TEXT PRIMARY KEY,
            decision_id TEXT NOT NULL,
            event_id TEXT,
            category TEXT NOT NULL,
            delivery_state TEXT NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            attempted_at REAL,
            delivered_at REAL,
            failure_code TEXT,
            FOREIGN KEY(decision_id) REFERENCES alert_decisions(id) ON DELETE CASCADE,
            FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_notification_pending ON notification_outbox(delivery_state, expires_at);
        CREATE TABLE IF NOT EXISTS notification_policy_state (
            key TEXT PRIMARY KEY,
            severity TEXT NOT NULL,
            last_sent_at REAL,
            recovered_samples INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS command_receipts (
            request_id TEXT PRIMARY KEY,
            command TEXT NOT NULL,
            result TEXT NOT NULL,
            detail_code TEXT,
            applied_revision INTEGER,
            processed_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS event_feedback (
            id TEXT PRIMARY KEY,
            event_id TEXT NOT NULL,
            feedback_kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            revoked_at REAL,
            FOREIGN KEY(event_id) REFERENCES storage_events(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_feedback_active ON event_feedback(event_id, revoked_at);
        """
}
