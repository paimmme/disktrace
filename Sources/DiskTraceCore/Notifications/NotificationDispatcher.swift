import Foundation

/// Drives the outbox: expires stale items, applies quiet hours and cooldown,
/// calls the sink, and records the result. Testable offline with an injected
/// sink; the production sink uses `UNUserNotificationCenter` inside the agent app.
public struct NotificationDispatcher: Sendable {
    public struct Report: Sendable, Equatable {
        public var delivered = 0
        public var deferred = 0
        public var dropped = 0
        public var failed = 0
        public init() {}
    }

    private let config: NotificationConfig
    private let sink: NotificationSink

    public init(config: NotificationConfig, sink: NotificationSink) {
        self.config = config
        self.sink = sink
    }

    @discardableResult
    public func flush(store: DiskTraceStore, now: Date) async -> Report {
        var report = Report()
        guard config.enabled else { return report }
        try? await store.expireOldNotifications(now: now)
        let items = (try? await store.notificationsToDeliver(now: now)) ?? []
        for item in items {
            let key = "notify:\(item.category.rawValue)"
            let lastSent = (try? await store.policyState(key: key))??.lastSentAt
            let cooldown = NotificationPolicy.cooldown(for: item.category, config: config)
            let decision = NotificationPolicy.evaluate(
                category: item.category, now: now, expiresAt: item.expiresAt,
                quietHours: config.quietHours,
                criticalBypassesQuietHours: config.criticalBypassesQuietHours,
                lastSentAt: lastSent, cooldown: cooldown)
            switch decision.action {
            case .drop:
                report.dropped += 1
                try? await store.updateNotification(
                    id: item.id, state: decision.reason == "expired" ? .expired : .failed, at: now,
                    failureCode: decision.reason)
            case .deferred:
                report.deferred += 1
                try? await store.updateNotification(
                    id: item.id, state: .deferredQuietHours, at: now)
            case .deliver:
                let title = NotificationCopy.title(category: item.category)
                let event = if let id = item.eventID { try? await store.event(id: id) } else { nil as StorageEvent? }
                let samples = try? await store.timelineSamples(from: now.addingTimeInterval(-180), to: now)
                let free = samples?.last.flatMap { $0.status == .available ? $0.freeBytes : nil }
                let body = NotificationCopy.body(category: item.category, freeBytes: free,
                    scopeName: event?.scopePath, netBytes: event?.netBytes, detail: false)
                let result = await sink.deliver(
                    item: item, title: title, body: body, eventID: item.eventID)
                switch result {
                case .acceptedByOS:
                    report.delivered += 1
                    try? await store.updateNotification(id: item.id, state: .acceptedByOS, at: now)
                    try? await store.setPolicyState(
                        key: key, severity: item.category.rawValue, lastSentAt: now,
                        recoveredSamples: 0, at: now)
                case .denied:
                    report.failed += 1
                    try? await store.updateNotification(
                        id: item.id, state: .denied, at: now, failureCode: "denied")
                case .failed:
                    report.failed += 1
                    try? await store.updateNotification(
                        id: item.id, state: .failed, at: now, failureCode: "failed")
                }
            }
        }
        return report
    }
}
