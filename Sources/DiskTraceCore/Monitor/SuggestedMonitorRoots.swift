import Foundation

public enum SuggestedMonitorRoots {
    /// Common locations where coding agents and build tooling accumulate data.
    /// Only paths that exist on disk are returned; the home directory is always first.
    public static func codingAgentDefaults(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = [home]
        let relativePaths = [
            "Library/Caches",
            "Library/Developer/Xcode/DerivedData",
            "Library/Application Support/Cursor",
            ".npm",
            ".cache",
            ".cursor",
            ".codex",
            "go/pkg/mod",
        ]
        for relative in relativePaths {
            let url = home.appending(path: relative, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: url.path) { urls.append(url) }
        }
        return urls
    }
}
