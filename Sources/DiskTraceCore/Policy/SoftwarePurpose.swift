import Foundation

/// Software / system grouping for interval reports. Labels path *usage*, not task writers.
public enum SoftwarePurpose: String, Codable, Sendable, CaseIterable {
    case codexAutoUpdate
    case codexSessionData
    case harnessAutoUpdate
    case claudeCache
    case systemSwap
    case monitoredOther
    case uncoveredVolume

    public var displayName: String {
        switch self {
        case .codexAutoUpdate: return "Codex 自动更新/下载缓存"
        case .codexSessionData: return "Codex 会话与本地数据"
        case .harnessAutoUpdate: return "Harness 更新/缓存"
        case .claudeCache: return "Claude 本地/缓存"
        case .systemSwap: return "系统交换区"
        case .monitoredOther: return "已监控路径（其他）"
        case .uncoveredVolume: return "卷级未解释差额"
        }
    }

    public var attributionNote: String {
        switch self {
        case .codexAutoUpdate, .harnessAutoUpdate:
            return "软件更新或安装缓存；不能据此认定为某次编码任务写入。"
        case .codexSessionData, .claudeCache:
            return "会话或客户端数据增长；与具体任务仅有弱关联，需任务证据。"
        case .systemSwap:
            return "系统内存压力下的交换；不因 Agent 同时运行而归因给它。"
        case .monitoredOther:
            return "已观测到的文件变化；来源仍可能未知。"
        case .uncoveredVolume:
            return "卷可用空间变化中未能用已监控路径与 swap 解释的部分；可能含未监控目录、APFS 共享块或方法差异。"
        }
    }
}

public enum SoftwarePurposeClassifier {
    public static func purpose(for path: String) -> SoftwarePurpose {
        let lower = path.lowercased()
        if lower.contains("/library/caches/com.openai.codex")
            || lower.contains("/library/caches/codex/")
            || lower.contains("/library/caches/openai.codex")
            || lower.contains("/library/caches/com.openai.chatgpt")
            || lower.contains(".codex/update")
            || lower.contains("/codex/update")
        {
            return .codexAutoUpdate
        }
        if lower.contains("/.codex/sessions") || lower.hasSuffix("/.codex") || lower.contains("/.codex/") {
            return .codexSessionData
        }
        if lower.contains("harness") && lower.contains("/library/caches/") { return .harnessAutoUpdate }
        if lower.contains("/.claude") || lower.contains("anthropic.claude") || lower.contains("/.cache/claude") {
            return .claudeCache
        }
        return .monitoredOther
    }
}
