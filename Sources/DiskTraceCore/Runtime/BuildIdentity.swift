import Foundation

/// Records which binary opened the database, for UI and ops verification.
public enum BuildIdentity {
    public static let schemaVersion = DiskTraceSchemaVersion.current

    /// Written once per writer session when the agent starts.
    public static func record(store: DiskTraceStore, gitCommit: String?, appVersion: String?) async {
        let now = Date()
        try? await store.setState("build_schema", String(schemaVersion), at: now)
        if let gitCommit, !gitCommit.isEmpty {
            try? await store.setState("build_git_commit", gitCommit, at: now)
        }
        if let appVersion, !appVersion.isEmpty {
            try? await store.setState("build_app_version", appVersion, at: now)
        }
        try? await store.setState("build_recorded_at", String(now.timeIntervalSince1970), at: now)
    }

    /// Best-effort commit from compile-time env or `.git/HEAD` near the process cwd.
    public static func resolveGitCommit() -> String? {
        if let env = ProcessInfo.processInfo.environment["DISKTRACE_GIT_COMMIT"], !env.isEmpty {
            return env
        }
        let fm = FileManager.default
        var url = URL(filePath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let head = url.appending(path: ".git/HEAD")
            if let line = try? String(contentsOf: head, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                if line.hasPrefix("ref: ") {
                    let ref = String(line.dropFirst(5))
                    let refPath = url.appending(path: ".git/\(ref)")
                    if let hash = try? String(contentsOf: refPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines), hash.count >= 7
                    {
                        return String(hash.prefix(12))
                    }
                } else if line.count >= 7 { return String(line.prefix(12)) }
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
