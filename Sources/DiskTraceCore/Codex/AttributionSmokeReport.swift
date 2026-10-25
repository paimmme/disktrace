import Foundation

/// Read-only summary: how file events relate to Codex task windows (candidates only).
public struct AttributionSmokeReport: Sendable {
    public let fileChanges: Int
    public let eventsWithFiles: Int
    public let pathCandidateLinks: Int
    public let timeOnlyLinks: Int
    public let unknownAttributionEvents: Int
    public let note: String
}

public enum AttributionSmoke {
    public static func evaluate(store: DiskTraceStore, from: Date, to: Date) async throws -> AttributionSmokeReport {
        let changes = try await store.fileChanges(rootID: nil, from: from, to: to, limit: 2_000)
        let events = try await store.queryEvents(rootID: nil, from: from, to: to, limit: 500)
        var pathCandidates = 0
        var timeOnly = 0
        var unknownEvents = 0
        for event in events {
            if event.attributionClass == .unknown { unknownEvents += 1 }
            let links = try await store.queryTaskCandidates(eventID: event.id)
            pathCandidates += links.filter { $0.state == .pathCandidate }.count
            timeOnly += links.filter { $0.state == .timeOnly }.count
        }
        return AttributionSmokeReport(
            fileChanges: changes.count, eventsWithFiles: events.count,
            pathCandidateLinks: pathCandidates, timeOnlyLinks: timeOnly,
            unknownAttributionEvents: unknownEvents,
            note: "pathCandidate 仅表示路径/窗口线索，不是写入证明；timeOnly 不能用于归因。")
    }
}
