import Foundation
import Testing

@testable import DiskTraceCore

actor RecordingSink: NotificationSink {
    private(set) var items: [OutboxItem] = []
    var count: Int { items.count }
    func deliver(item: OutboxItem, title: String, body: String, eventID: UUID?) async -> NotificationSinkResult {
        items.append(item)
        return .acceptedByOS
    }
}

@Suite("Notifications (N-series)")
struct NotificationTests {
    private func item(_ decision: UUID, category: NotificationCategory, createdAt: Date, ttl: TimeInterval = 600) -> OutboxItem {
        OutboxItem(
            id: OutboxItem.stableID(decisionID: decision), decisionID: decision, eventID: nil,
            category: category, state: .pending, createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ttl))
    }

    private func ensureDecision(_ store: DiskTraceStore, _ id: UUID, at now: Date) async throws {
        try await store.insert(
            AlertDecision(
                id: id, ruleVersion: "1", subjectID: UUID(), action: .notifySafetyLowSpace,
                reason: .lowSpaceSafety, evidenceClass: .unknown, evaluatedAt: now))
    }

    @Test("N11: enqueuing the same decision twice keeps one outbox row")
    func outboxIdempotent() async throws {
        let store = try DiskTraceStore.inMemory()
        let decision = UUID()
        let now = Date()
        try await ensureDecision(store, decision, at: now)
        try await store.enqueueNotification(item(decision, category: .agentGrowth, createdAt: now))
        try await store.enqueueNotification(item(decision, category: .agentGrowth, createdAt: now))
        let pending = try await store.notificationsToDeliver(now: now)
        #expect(pending.count == 1)
    }

    @Test("N12: quiet hours defer, expiry drops, and critical bypasses quiet hours")
    func quietHoursAndExpiry() async throws {
        let now = Date()
        let quiet = QuietHours(startMinute: 0, endMinute: 1439)
        // Agent growth within quiet hours is deferred.
        #expect(
            NotificationPolicy.evaluate(
                category: .agentGrowth, now: now, expiresAt: now.addingTimeInterval(600),
                quietHours: quiet, criticalBypassesQuietHours: true, lastSentAt: nil, cooldown: 60
            ).action == .deferred)
        // Critical bypasses quiet hours.
        #expect(
            NotificationPolicy.evaluate(
                category: .criticalLowSpace, now: now, expiresAt: now.addingTimeInterval(600),
                quietHours: quiet, criticalBypassesQuietHours: true, lastSentAt: nil, cooldown: 60
            ).action == .deliver)
        // Expired item is dropped.
        #expect(
            NotificationPolicy.evaluate(
                category: .lowSpaceSafety, now: now, expiresAt: now.addingTimeInterval(-1),
                quietHours: nil, criticalBypassesQuietHours: true, lastSentAt: nil, cooldown: 60
            ).action == .drop)
    }

    @Test("N09: cooldown suppresses a repeat low-space notification")
    func cooldown() async throws {
        let store = try DiskTraceStore.inMemory()
        let sink = RecordingSink()
        let dispatcher = NotificationDispatcher(
            config: NotificationConfig(quietHours: nil), sink: sink)
        let now = Date()
        let d1 = UUID()
        try await ensureDecision(store, d1, at: now)
        try await store.enqueueNotification(item(d1, category: .lowSpaceSafety, createdAt: now))
        let first = await dispatcher.flush(store: store, now: now)
        #expect(first.delivered == 1)
        #expect(await sink.count == 1)

        let d2 = UUID()
        try await ensureDecision(store, d2, at: now.addingTimeInterval(10))
        try await store.enqueueNotification(
            item(d2, category: .lowSpaceSafety, createdAt: now.addingTimeInterval(10)))
        let second = await dispatcher.flush(store: store, now: now.addingTimeInterval(10))
        #expect(second.delivered == 0)
        #expect(second.dropped == 1)
        #expect(await sink.count == 1)
    }

    @Test("delivery records acceptedByOS, never 'user saw it'")
    func acceptedByOS() async throws {
        let store = try DiskTraceStore.inMemory()
        let sink = RecordingSink()
        let dispatcher = NotificationDispatcher(config: NotificationConfig(), sink: sink)
        let now = Date()
        let d = UUID()
        try await ensureDecision(store, d, at: now)
        try await store.enqueueNotification(item(d, category: .agentGrowth, createdAt: now, ttl: 1_800))
        _ = await dispatcher.flush(store: store, now: now)
        let state = try await store.policyState(key: "notify:agentGrowth")
        #expect(state?.lastSentAt != nil)
    }

    @Test("safety category thresholds classify low vs critical")
    func safetyCategories() {
        let config = NotificationConfig()
        #expect(config.safetyCategory(freeBytes: 1_000_000_000, capacityBytes: 1_000_000_000_000) == .criticalLowSpace)
        #expect(config.safetyCategory(freeBytes: 8_000_000_000, capacityBytes: 100_000_000_000) == .lowSpaceSafety)
        #expect(config.safetyCategory(freeBytes: 500_000_000_000, capacityBytes: 1_000_000_000_000) == nil)
    }

    @Test("notification copy never accuses the agent of downloading")
    func copyContract() {
        let text = NotificationCopy.body(
            category: .agentGrowth, freeBytes: nil, scopeName: "/Users/x/project", netBytes: 1, detail: false)
        #expect(text.contains("可能"))
        #expect(!text.contains("下载"))
        #expect(!text.contains("垃圾"))
        #expect(!text.contains("可放心删除"))
    }
}
