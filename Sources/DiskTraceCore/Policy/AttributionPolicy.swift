import Foundation

/// Path classification and task-link scoring — pure functions, no storage.
///
/// Classification answers only "where / what kind of file", never "who wrote
/// it". Path rules never raise source confidence on their own.
public enum AttributionPolicy {
    static let algorithmVersion = "attribution-v1"

    // MARK: - Path classification (§11.1)

    static let dependencySegments: Set<String> = ["node_modules", ".venv", "venv", "site-packages"]
    static let buildSegments: Set<String> = [
        ".build", ".next", "dist", "build", "target", "deriveddata", "out",
    ]
    static let modelCacheSegments: Set<String> = ["huggingface", "ollama", "torch", "whisper"]

    public static func classify(path: String) -> ReasonCategory {
        let segments = path.split(separator: "/").map { $0.lowercased() }
        let set = Set(segments)
        if !set.isDisjoint(with: dependencySegments) { return .dependencies }
        if set.contains("downloads") { return .downloadsFolder }
        if !set.isDisjoint(with: modelCacheSegments) { return .modelCache }
        if set.contains(".codex") {
            let artifacts: Set<String> = ["artifacts", "outputs", "visualizations"]
            if !set.isDisjoint(with: artifacts) { return .sessionArtifacts }
        }
        if !set.isDisjoint(with: buildSegments) { return .buildOutputs }
        if set.contains("tmp") || segments.contains(where: { $0.hasPrefix("tmp") }) {
            return .temporaryFiles
        }
        return .unknown
    }

    // MARK: - Path matching (§11.2)

    /// A file is inside a working directory when the path equals it or is below
    /// it. The root `/` gets an explicit boundary so `/etc` is not matched by `/`.
    public static func matches(filePath: String, workingDirectory cwd: String) -> Bool {
        if cwd == "/" { return filePath.hasPrefix("/") && filePath != "/" }
        return filePath == cwd || filePath.hasPrefix(cwd + "/")
    }

    /// Picks the most specific working directory that contains `path`, if any.
    public static func scopeMatch(filePath: String, directories: [String]) -> String? {
        directories
            .filter { matches(filePath: filePath, workingDirectory: $0) }
            .max(by: { $0.count < $1.count })
    }

    // MARK: - Link scoring (§11.3)

    public struct ScoredLink: Sendable, Hashable {
        public let activityID: UUID
        public let state: TaskLinkState
        public let basis: String
        public let candidateBytes: Int64?
        public let limitation: String
    }

    /// Scores candidate task windows for one event's file changes.
    public static func score(
        changes: [FileChange],
        candidates: [ResolvedCandidate],
        now: Date
    ) -> [ScoredLink] {
        guard !candidates.isEmpty else { return [] }
        let overlapping = candidates.filter { $0.overlaps }
        let matched = overlapping.filter { $0.isAncestorOfScope }
        let ambiguous = matched.count > 1

        return overlapping.map { candidate in
            let state: TaskLinkState
            let basis: String
            if !candidate.isAncestorOfScope {
                state = .timeOnly
                basis = "timeWindowOverlap"
            } else if ambiguous {
                state = .ambiguous
                basis = "workingDirectoryPathMatch+multipleCandidates"
            } else if candidate.confident {
                state = .pathCandidate
                basis = "workingDirectoryPathMatch"
            } else {
                state = .timeOnly
                basis = "workingDirectoryPathMatchButWindowUnverified"
            }
            let bytes = changes
                .filter { change in
                    guard let path = change.pathAfter ?? change.pathBefore else { return false }
                    return matches(filePath: path, workingDirectory: candidate.directory)
                }
                .reduce(into: Int64(0)) { sum, change in sum += change.deltaAllocated ?? 0 }
            let limitation =
                state == .pathCandidate
                ? "路径与工作目录匹配且任务窗口完整；这是关联线索，不是进程级写入证据。"
                : "仅时间或未验证线索；不能据此认定写入来源。"
            return ScoredLink(
                activityID: candidate.activity.id, state: state, basis: basis,
                candidateBytes: state == .pathCandidate ? bytes : nil, limitation: limitation)
        }
    }

    /// A candidate window paired with its working directory and confidence.
    public struct ResolvedCandidate: Sendable, Hashable {
        public let activity: AgentActivity
        public let directory: String
        public let overlaps: Bool
        public let isAncestorOfScope: Bool
        public let confident: Bool

        public init(
            activity: AgentActivity, directory: String, overlaps: Bool,
            isAncestorOfScope: Bool, confident: Bool
        ) {
            self.activity = activity
            self.directory = directory
            self.overlaps = overlaps
            self.isAncestorOfScope = isAncestorOfScope
            self.confident = confident
        }
    }

    public static func attributionClass(for links: [ScoredLink]) -> EventAttributionClass {
        // No process-level capability exists, so `agentConfirmed` is never produced.
        if links.contains(where: { $0.state == .userConfirmed }) { return .userConfirmed }
        let pathCandidates = links.filter { $0.state == .pathCandidate }
        if pathCandidates.count == 1, !links.contains(where: { $0.state == .ambiguous }) {
            return .agentProbable
        }
        return .unknown
    }
}
