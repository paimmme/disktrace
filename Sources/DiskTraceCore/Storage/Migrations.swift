import Foundation

/// Versioned, transactional schema migrations. The schema is deliberately small
/// and access-pattern driven rather than fully normalized.
enum Migrations {
    static let currentVersion = 3

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
    }

    private static func readVersion(_ database: SQLiteDatabase) throws -> Int {
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
}
