import Foundation

/// Optional, bounded monitoring roots for agent software caches/updates.
/// Only paths that exist on disk are returned; never whole `Library` or disk.
public enum MonitorPresets {
    public struct Suggestion: Sendable, Hashable {
        public let url: URL
        public let label: String
        public let purpose: SoftwarePurpose
    }

    public static func suggestedOptionalRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [Suggestion]
    {
        let homePath = home.path
        let candidates: [(String, String, SoftwarePurpose)] = [
            ("\(homePath)/Library/Caches/com.openai.codex", "Codex 更新/下载缓存", .codexAutoUpdate),
            ("\(homePath)/Library/Caches/Codex", "Codex 浏览器/应用缓存", .codexAutoUpdate),
            ("\(homePath)/Library/Caches/com.openai.codex.update", "Codex 更新包", .codexAutoUpdate),
            ("\(homePath)/Library/Caches/openai.codex", "Codex 缓存（旧路径）", .codexAutoUpdate),
            ("\(homePath)/Library/Caches/com.openai.chatgpt", "ChatGPT/Codex 相关缓存", .codexAutoUpdate),
            ("\(homePath)/.codex/sessions", "Codex 会话数据", .codexSessionData),
            ("\(homePath)/.codex", "Codex 主目录（含会话与产物）", .codexSessionData),
            ("\(homePath)/Library/Caches/com.openai.harness", "Harness 更新/缓存", .harnessAutoUpdate),
            ("\(homePath)/Library/Caches/Harness", "Harness 缓存", .harnessAutoUpdate),
            ("\(homePath)/Library/Caches/com.anthropic.claude", "Claude 缓存", .claudeCache),
            ("\(homePath)/.claude", "Claude 本地数据", .claudeCache),
            ("\(homePath)/.cache/claude", "Claude 缓存（XDG）", .claudeCache),
        ]
        var seen = Set<String>()
        var result: [Suggestion] = []
        for (path, label, purpose) in candidates {
            let canonical = FilePaths.canonical(path)
            guard seen.insert(canonical).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir), isDir.boolValue
            else { continue }
            result.append(Suggestion(url: URL(filePath: canonical), label: label, purpose: purpose))
        }
        return result
    }

    /// Merges configured roots with optional presets the caller explicitly enables.
    public static func mergeRoots(configured: [URL], optional: [URL]) -> [URL] {
        var paths = Set(configured.map { FilePaths.canonical($0.path) })
        var merged = configured
        for url in optional {
            let c = FilePaths.canonical(url.path)
            if paths.insert(c).inserted { merged.append(URL(filePath: c)) }
        }
        return merged
    }
}
