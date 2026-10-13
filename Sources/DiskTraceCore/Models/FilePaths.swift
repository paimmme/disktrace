import Darwin
import Foundation

/// Canonical path helpers. macOS firmlinks (`/var` -> `/private/var`) mean two
/// spellings of the same directory must be reconciled before they are compared,
/// stored or used as dictionary keys.
public enum FilePaths {
    /// Resolves symbols/links to a canonical absolute path. Returns the input
    /// (sans trailing slash) when the path cannot be resolved.
    public static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    public static func canonical(url: URL) -> String { canonical(url.path) }
}
