import Foundation

/// In-memory index of minimal agent activities for fast time/path queries.
/// Holds only the whitelisted `AgentActivity` fields — never content.
public struct AgentActivityIndex: Sendable {
    private let activities: [AgentActivity]

    public init(activities: [AgentActivity]) {
        self.activities = activities.sorted { $0.startedAt < $1.startedAt }
    }

    public var count: Int { activities.count }

    public func overlapping(start: Date, end: Date) -> [AgentActivity] {
        activities.filter { $0.overlaps(start: start, end: end) }
    }

    public func forPath(_ path: String) -> [AgentActivity] {
        activities.filter { activity in
            guard let directory = activity.workingDirectory else { return false }
            return path == directory || path.hasPrefix(directory + "/")
        }
    }
}
