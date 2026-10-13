import Foundation

/// Persistent notification outbox and per-category policy state.
extension DiskTraceStore {

    public func enqueueNotification(_ item: OutboxItem) throws {
        let statement = try database.prepare(
            """
            INSERT OR IGNORE INTO notification_outbox
            (id, decision_id, event_id, category, delivery_state, created_at, expires_at,
             attempted_at, delivered_at, failure_code)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """)
        try statement.run([
            .text(item.id.uuidString), .text(item.decisionID.uuidString),
            .optionalText(item.eventID?.uuidString), .text(item.category.rawValue),
            .text(item.state.rawValue), .date(item.createdAt), .date(item.expiresAt),
            .optionalDate(item.attemptedAt), .optionalDate(item.deliveredAt),
            .optionalText(item.failureCode),
        ])
    }

    public func notificationsToDeliver(now: Date, limit: Int = 50) throws -> [OutboxItem] {
        let statement = try database.prepare(
            """
            SELECT id, decision_id, event_id, category, delivery_state, created_at, expires_at,
                   attempted_at, delivered_at, failure_code
            FROM notification_outbox
            WHERE delivery_state IN ('pending','deferredQuietHours') AND expires_at > ?
            ORDER BY created_at ASC LIMIT ?;
            """)
        try statement.bind([.date(now), .int(Int64(limit))])
        var result: [OutboxItem] = []
        while try statement.step() {
            result.append(
                OutboxItem(
                    id: UUID(uuidString: statement.text(0)) ?? UUID(),
                    decisionID: UUID(uuidString: statement.text(1)) ?? UUID(),
                    eventID: statement.optionalText(2).flatMap(UUID.init(uuidString:)),
                    category: NotificationCategory(rawValue: statement.text(3)) ?? .lowSpaceSafety,
                    state: DeliveryState(rawValue: statement.text(4)) ?? .pending,
                    createdAt: statement.date(5), expiresAt: statement.date(6),
                    attemptedAt: statement.optionalDate(7),
                    deliveredAt: statement.optionalDate(8),
                    failureCode: statement.optionalText(9)))
        }
        return result
    }

    public func updateNotification(
        id: UUID, state: DeliveryState, at date: Date, failureCode: String? = nil
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE notification_outbox SET delivery_state=?, attempted_at=?,
                delivered_at=CASE WHEN ?='acceptedByOS' THEN ? ELSE delivered_at END,
                failure_code=?
            WHERE id=?;
            """)
        try statement.run([
            .text(state.rawValue), .date(date), .text(state.rawValue), .date(date),
            .optionalText(failureCode), .text(id.uuidString),
        ])
    }

    public func expireOldNotifications(now: Date) throws {
        try rawExecute(
            "UPDATE notification_outbox SET delivery_state='expired' WHERE delivery_state IN ('pending','deferredQuietHours') AND expires_at<=?;",
            [.date(now)])
    }

    // MARK: - Policy state

    public func policyState(key: String) throws -> (lastSentAt: Date?, recoveredSamples: Int)? {
        let statement = try database.prepare(
            "SELECT last_sent_at, recovered_samples FROM notification_policy_state WHERE key=?;")
        guard try statement.run([.text(key)]) else { return nil }
        return (statement.optionalDate(0), statement.int(1))
    }

    public func setPolicyState(
        key: String, severity: String, lastSentAt: Date?, recoveredSamples: Int, at date: Date
    ) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO notification_policy_state
            (key, severity, last_sent_at, recovered_samples, updated_at) VALUES (?,?,?,?,?);
            """)
        try statement.run([
            .text(key), .text(severity), .optionalDate(lastSentAt), .int(Int64(recoveredSamples)),
            .date(date),
        ])
    }
}
