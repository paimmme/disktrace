import Foundation

/// Why inventory scanning is degraded — separate from `RootState.quotaLimited`.
public enum RootLimitationKind: String, Codable, Sendable {
    case lowSpace
    case rowBudget
    case byteBudget
    case permission
    case paused

    public var displayName: String {
        switch self {
        case .lowSpace: return "磁盘可用空间过低，完整扫描已暂停"
        case .rowBudget: return "库存行数预算已满，完整扫描已暂停"
        case .byteBudget: return "库存字节预算已满，完整扫描已暂停"
        case .permission: return "目录权限不足"
        case .paused: return "监控已暂停"
        }
    }
}
