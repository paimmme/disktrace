import Foundation

/// Pure event assembly (§10). Groups concrete file changes into user-facing
/// storage events by (root, scope, 5-minute UTC bucket), scores task candidates,
/// and never lets a root event inherit a project's attribution.
public enum EventAssembler {
    public static let bucketSeconds: TimeInterval = 300

    public struct Assembled: Sendable {
        public let event: StorageEvent
        public let changeIDs: [UUID]
        public let links: [TaskLink]
    }

    public static func assemble(
        changes: [FileChange],
        windows: [TaskWindow],
        activities: [UUID: AgentActivity],
        roots: [UUID: String],
        configRevision: Int,
        now: Date
    ) -> [Assembled] {
        guard !changes.isEmpty else { return [] }

        struct BucketKey: Hashable { let root: UUID; let scope: String; let bucket: Int }
        var groups: [BucketKey: [FileChange]] = [:]

        for change in changes {
            let scope = scopePath(for: change, windows: windows, activities: activities, roots: roots)
            let bucket = Int((change.observedAt.timeIntervalSince1970 / bucketSeconds).rounded(.down))
            groups[BucketKey(root: change.rootID, scope: scope, bucket: bucket), default: []]
                .append(change)
        }

        var result: [Assembled] = []
        for (key, groupChanges) in groups {
            let bucketStart = Date(timeIntervalSince1970: Double(key.bucket) * bucketSeconds)
            let eventID = StorageEvent.stableID(
                rootID: key.root, scopePath: key.scope, bucketStart: bucketStart,
                configRevision: configRevision)

            let resolved = resolveCandidates(
                changes: groupChanges, windows: windows, activities: activities, scope: key.scope,
                now: now)
            let links = AttributionPolicy.score(changes: groupChanges, candidates: resolved, now: now)
            let attribution = AttributionPolicy.attributionClass(for: links)

            let measuredDeltas = groupChanges.compactMap(\.deltaAllocated)
            let net: Int64? = measuredDeltas.count == groupChanges.count
                ? measuredDeltas.reduce(0, +) : nil
            let grossAdded = measuredDeltas.filter { $0 > 0 }.reduce(0, +)
            let grossRemoved = measuredDeltas.filter { $0 < 0 }.reduce(0, +)

            let candidateDirs = Set(resolved.filter(\.isAncestorOfScope).map(\.directory))
            let unassigned: Int64? = net == nil ? nil : groupChanges.reduce(into: Int64(0)) { sum, change in
                guard let path = change.pathAfter ?? change.pathBefore else { return }
                let underCandidate = candidateDirs.contains { AttributionPolicy.matches(filePath: path, workingDirectory: $0) }
                if !underCandidate { sum += change.deltaAllocated ?? 0 }
            }

            let categories = Set(groupChanges.map { change -> ReasonCategory in
                AttributionPolicy.classify(path: change.pathAfter ?? change.pathBefore ?? "")
            })
            let reason: ReasonCategory
            if categories.count > 1 { reason = .mixed }
            else { reason = categories.first ?? .unknown }

            let measurement: MeasurementState =
                measuredDeltas.count == groupChanges.count ? .measured : .beforeUnknown

            let event = StorageEvent(
                id: eventID, rootID: key.root, scopePath: key.scope,
                windowStart: bucketStart, windowEnd: bucketStart.addingTimeInterval(bucketSeconds),
                grossAddedBytes: grossAdded, grossRemovedBytes: grossRemoved, netBytes: net,
                measurement: measurement, reasonCategory: reason, attributionClass: attribution,
                candidateCount: Set(links.map(\.activityID)).count, unassignedBytes: unassigned,
                status: .ready, createdAt: now, updatedAt: now)

            let taskLinks = links.map { link in
                TaskLink(
                    eventID: eventID, activityID: link.activityID, state: link.state,
                    basis: link.basis, candidateBytes: link.candidateBytes,
                    algorithmVersion: AttributionPolicy.algorithmVersion, limitation: link.limitation)
            }
            result.append(
                Assembled(event: event, changeIDs: groupChanges.map(\.id), links: taskLinks))
        }
        return result.sorted { $0.event.windowStart < $1.event.windowStart }
    }

    // MARK: - Scope resolution

    static func scopePath(
        for change: FileChange, windows: [TaskWindow], activities: [UUID: AgentActivity],
        roots: [UUID: String]
    ) -> String {
        let root = roots[change.rootID] ?? "/"
        let path = change.pathAfter ?? change.pathBefore ?? root
        let matched = windows.compactMap { window -> String? in
            guard let directory = activities[window.activityID]?.workingDirectory,
                activities[window.activityID]?.overlaps(
                    start: change.windowStart, end: change.windowEnd) == true,
                AttributionPolicy.matches(filePath: path, workingDirectory: directory)
            else { return nil }
            return directory
        }
        if let scope = matched.max(by: { $0.count < $1.count }) { return scope }
        if let classified = firstClassifiedDirectory(path: path, root: root) { return classified }
        return parentDirectory(path: path, root: root)
    }

    static func firstClassifiedDirectory(path: String, root: String) -> String? {
        let rootComponents = root.split(separator: "/").map(String.init)
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= rootComponents.count else { return nil }
        let classifiedSegments =
            AttributionPolicy.dependencySegments
            .union(AttributionPolicy.buildSegments)
            .union(AttributionPolicy.modelCacheSegments)
        for index in rootComponents.count..<components.count {
            if classifiedSegments.contains(components[index].lowercased()) {
                return "/" + components[0...index].joined(separator: "/")
            }
        }
        return nil
    }

    static func parentDirectory(path: String, root: String) -> String {
        if path == root { return root }
        guard let index = path.lastIndex(of: "/"), index != path.startIndex else { return root }
        let parent = String(path[..<index])
        return parent.count >= root.count ? parent : root
    }

    static func resolveCandidates(
        changes: [FileChange], windows: [TaskWindow], activities: [UUID: AgentActivity],
        scope: String, now: Date
    ) -> [AttributionPolicy.ResolvedCandidate] {
        let windowStart = changes.map(\.windowStart).min() ?? now
        let windowEnd = changes.map(\.windowEnd).max() ?? now
        return windows.compactMap { window -> AttributionPolicy.ResolvedCandidate? in
            guard let activity = activities[window.activityID],
                let directory = activity.workingDirectory
            else { return nil }
            let overlaps = activity.overlaps(start: windowStart, end: windowEnd)
            return AttributionPolicy.ResolvedCandidate(
                activity: activity, directory: directory, overlaps: overlaps,
                isAncestorOfScope: AttributionPolicy.matches(
                    filePath: scope, workingDirectory: directory)
                    || scope == directory,
                confident: window.isConfidentCandidate(now: now))
        }
    }
}
