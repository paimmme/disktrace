import CryptoKit
import Foundation

public enum NotificationCategory: String, Codable, Sendable {
    case agentGrowth
    case lowSpaceSafety
    case criticalLowSpace
}

/// Delivery state. `acceptedByOS` means the OS accepted the request — it is
/// **not** proof the user saw it.
public enum DeliveryState: String, Codable, Sendable {
    case pending
    case acceptedByOS
    case denied
    case deferredQuietHours
    case expired
    case failed
}

public struct OutboxItem: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let decisionID: UUID
    public let eventID: UUID?
    public let category: NotificationCategory
    public var state: DeliveryState
    public let createdAt: Date
    public let expiresAt: Date
    public var attemptedAt: Date?
    public var deliveredAt: Date?
    public var failureCode: String?

    public init(
        id: UUID, decisionID: UUID, eventID: UUID?, category: NotificationCategory,
        state: DeliveryState, createdAt: Date, expiresAt: Date, attemptedAt: Date? = nil,
        deliveredAt: Date? = nil, failureCode: String? = nil
    ) {
        self.id = id
        self.decisionID = decisionID
        self.eventID = eventID
        self.category = category
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.attemptedAt = attemptedAt
        self.deliveredAt = deliveredAt
        self.failureCode = failureCode
    }

    /// `notification-v1|decisionID` — a crash retry reuses the same id.
    public static func stableID(decisionID: UUID) -> UUID {
        let key = "notification-v1|\(decisionID.uuidString)"
        return Fingerprint.uuid(key)
    }
}

public struct QuietHours: Codable, Sendable, Hashable {
    public var startMinute: Int  // 0..1439
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute <= endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute  // wraps midnight
    }
}

public enum NotificationSinkResult: String, Sendable {
    case acceptedByOS
    case denied
    case failed
}

/// A delivery backend. The real implementation uses `UNUserNotificationCenter`;
/// tests inject an offline sink.
public protocol NotificationSink: Sendable {
    func deliver(item: OutboxItem, title: String, body: String, eventID: UUID?) async -> NotificationSinkResult
}

/// Decides whether an outbox item may be delivered now, given quiet hours,
/// expiry and the persisted per-category cooldown.
public enum NotificationPolicy {
    public struct Decision: Sendable {
        public enum Action: Sendable { case deliver, deferred, drop }
        public let action: Action
        public let reason: String
    }

    public static func evaluate(
        category: NotificationCategory, now: Date, expiresAt: Date, quietHours: QuietHours?,
        criticalBypassesQuietHours: Bool, lastSentAt: Date?, cooldown: TimeInterval
    ) -> Decision {
        if now > expiresAt { return Decision(action: .drop, reason: "expired") }
        let critical = category == .criticalLowSpace
        if let quietHours, quietHours.contains(now), !(critical && criticalBypassesQuietHours) {
            return Decision(action: .deferred, reason: "quietHours")
        }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < cooldown {
            return Decision(action: .drop, reason: "cooldown")
        }
        return Decision(action: .deliver, reason: "ok")
    }

    public static func cooldown(for category: NotificationCategory, config: NotificationConfig) -> TimeInterval {
        switch category {
        case .agentGrowth: return config.agentCooldownSeconds
        case .lowSpaceSafety: return config.safetyCooldownSeconds
        case .criticalLowSpace: return config.criticalCooldownSeconds
        }
    }

    public static func expiry(for category: NotificationCategory) -> TimeInterval {
        category == .agentGrowth ? 1_800 : 600
    }
}

/// Notification-related configuration (mirrors the config contract).
public struct NotificationConfig: Sendable {
    public var enabled: Bool
    public var agentGrowthBytes: Int64
    public var agentGrowthWindowSeconds: TimeInterval
    public var agentCooldownSeconds: TimeInterval
    public var lowFreeBytes: Int64
    public var lowFreeFraction: Double
    public var criticalFreeBytes: Int64
    public var criticalFreeFraction: Double
    public var safetyCooldownSeconds: TimeInterval
    public var criticalCooldownSeconds: TimeInterval
    public var quietHours: QuietHours?
    public var criticalBypassesQuietHours: Bool

    public init(
        enabled: Bool = true, agentGrowthBytes: Int64 = 128_000_000,
        agentGrowthWindowSeconds: TimeInterval = 300, agentCooldownSeconds: TimeInterval = 1_800,
        lowFreeBytes: Int64 = 10_000_000_000, lowFreeFraction: Double = 0.05,
        criticalFreeBytes: Int64 = 2_000_000_000, criticalFreeFraction: Double = 0.01,
        safetyCooldownSeconds: TimeInterval = 1_800, criticalCooldownSeconds: TimeInterval = 300,
        quietHours: QuietHours? = nil, criticalBypassesQuietHours: Bool = true
    ) {
        self.enabled = enabled
        self.agentGrowthBytes = agentGrowthBytes
        self.agentGrowthWindowSeconds = agentGrowthWindowSeconds
        self.agentCooldownSeconds = agentCooldownSeconds
        self.lowFreeBytes = lowFreeBytes
        self.lowFreeFraction = lowFreeFraction
        self.criticalFreeBytes = criticalFreeBytes
        self.criticalFreeFraction = criticalFreeFraction
        self.safetyCooldownSeconds = safetyCooldownSeconds
        self.criticalCooldownSeconds = criticalCooldownSeconds
        self.quietHours = quietHours
        self.criticalBypassesQuietHours = criticalBypassesQuietHours
    }

    /// Classifies free space into a safety category, or nil when healthy.
    public func safetyCategory(freeBytes: Int64, capacityBytes: Int64) -> NotificationCategory? {
        guard capacityBytes > 0 else { return nil }
        let fraction = Double(freeBytes) / Double(capacityBytes)
        if freeBytes < criticalFreeBytes || fraction < criticalFreeFraction { return .criticalLowSpace }
        if freeBytes < lowFreeBytes || fraction < lowFreeFraction { return .lowSpaceSafety }
        return nil
    }
}

/// Builds the user-facing notification text. Contracts allow "可能与 … 有关";
/// they forbid "Codex 偷偷下载", "垃圾", "可放心删除".
public enum NotificationCopy {
    public static func title(category: NotificationCategory) -> String {
        switch category {
        case .agentGrowth: return "磁盘上有与任务相关的目录增长"
        case .lowSpaceSafety: return "磁盘可用空间偏低"
        case .criticalLowSpace: return "磁盘空间紧张"
        }
    }
    public static func body(
        category: NotificationCategory, freeBytes: Int64?, scopeName: String?, netBytes: Int64?,
        detail: Bool
    ) -> String {
        switch category {
        case .lowSpaceSafety:
            return "剩余 \(freeBytes.map(bytesText) ?? "未知")。点击查看近期增长目录。"
        case .criticalLowSpace:
            return "剩余 \(freeBytes.map(bytesText) ?? "未知")。部分增长尚未找到原因。"
        case .agentGrowth:
            let name = scopeName.map { detail ? shortPath($0) : URL(filePath: $0).lastPathComponent } ?? "某目录"
            return "可能与 Codex 任务有关：\(name) 在相关时段净增 \(netBytes.map(bytesText) ?? "未知")。点击查看文件与证据。"
        }
    }
    static func bytesText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

enum Fingerprint {
    static func uuid(_ key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]))
    }
}
