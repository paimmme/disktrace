import Foundation

public enum UserRuleKind: String, Codable, Sendable {
    /// "This was my own action" — silence agent alerts for the scope.
    case silenceSource
    /// Explicit user confirmation that changes in the scope are expected.
    case confirmUser
    /// Keep an eye on this source (does not silence).
    case watch
}

/// A local, explainable, revocable user rule. Rules only affect notifications —
/// they never delete observation history.
public struct UserRule: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: UserRuleKind
    public let pathPattern: String
    public let createdAt: Date
    public let expiresAt: Date?
    public let explanation: String
    public var isRevoked: Bool

    public init(
        id: UUID = UUID(),
        kind: UserRuleKind,
        pathPattern: String,
        createdAt: Date,
        expiresAt: Date? = nil,
        explanation: String,
        isRevoked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.pathPattern = UserRulePaths.normalize(pathPattern)
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.explanation = explanation
        self.isRevoked = isRevoked
    }

    public func isActive(at date: Date) -> Bool {
        guard !isRevoked else { return false }
        if let expiresAt, date > expiresAt { return false }
        return true
    }

    public func matches(path: String, at date: Date) -> Bool {
        guard isActive(at: date) else { return false }
        return UserRulePaths.matches(pattern: pathPattern, path: path)
    }
}

/// Small, dependency-free glob matcher: `*` matches within a path segment,
/// `**` matches across segments, and a trailing `/**` matches the subtree.
public enum UserRulePaths {
    public static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func matches(pattern rawPattern: String, path rawPath: String) -> Bool {
        let pattern = normalize(rawPattern)
        let path = normalize(rawPath)
        if pattern.isEmpty { return false }
        if pattern.hasSuffix("/**") {
            let base = String(pattern.dropLast(3))
            return path == base || path.hasPrefix(base + "/")
        }
        if !pattern.contains("*") {
            // A rule on a directory covers its whole subtree.
            return path == pattern || path.hasPrefix(pattern + "/")
        }
        return globMatch(Array(pattern), Array(path))
    }

    private static func globMatch(_ pattern: [Character], _ path: [Character]) -> Bool {
        var pi = 0
        var si = 0
        var starPi = -1
        var starSi = 0
        while si < path.count {
            if pi < pattern.count, pattern[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
            } else if pi < pattern.count, pattern[pi] == path[si] {
                pi += 1
                si += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starSi += 1
                si = starSi
            } else {
                return false
            }
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }
}
