import AppKit
import DiskTraceCore
import Foundation

struct GrowthSummary: Identifiable {
    var id: String { path }
    let path: String
    let netBytes: Int64
    let latest: DirectoryDelta
    let decision: AlertDecision?
    let windows: Int
    var name: String { URL(filePath: path).lastPathComponent }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "最近 1 小时", day = "最近 24 小时", week = "最近 7 天"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .hour: return 3_600; case .day: return 86_400; case .week: return 604_800 }
    }
}

/// The interface opens a query-only connection; the agent owns all writes and migrations.
@MainActor
final class AppModel: ObservableObject {
    @Published var samples: [VolumeSample] = []
    @Published var latestSample: VolumeSample?
    @Published var deltas: [DirectoryDelta] = []
    @Published var decisions: [AlertDecision] = []
    @Published var gaps: [CoverageGap] = []
    @Published var roots: [String] = []
    @Published var range: HistoryRange = .day
    @Published var databasePath: String
    @Published var refreshedAt: Date?
    @Published var errorMessage: String?
    @Published var refreshing = false
    @Published var databaseBytes: Int64 = 0
    @Published var activityCount = 0
    @Published var events: [StorageEvent] = []
    @Published var selectedEventID: UUID?
    @Published var eventFiles: [FileChange] = []
    @Published var eventLinks: [TaskLink] = []
    @Published var eventPresence: [PresenceCheck] = []
    private var store: DiskTraceStore?
    private var openedPath: String?

    init(databasePath: String? = nil) {
        self.databasePath = databasePath ?? Self.defaultDatabasePath()
    }

    static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DiskTrace/disktrace.sqlite").path
    }

    var isFresh: Bool {
        guard let sample = latestSample, sample.status == .available, let refreshedAt else { return false }
        return refreshedAt.timeIntervalSince(sample.observedAt) < 180
    }
    var lowSpace: Bool {
        guard let sample = latestSample, sample.status == .available else { return false }
        return sample.freeBytes < 10_000_000_000 || sample.freeFraction < 0.05
    }
    var spaceChange: Int64? {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else { return nil }
        return last.freeBytes - first.freeBytes
    }
    var growth: [GrowthSummary] {
        let bySubject = Dictionary(grouping: decisions, by: \.subjectID)
        return Dictionary(grouping: deltas, by: \.pathID).compactMap { path, rows in
            guard let latest = rows.max(by: { $0.windowEnd < $1.windowEnd }) else { return nil }
            let net = rows.reduce(Int64(0)) { $0 + $1.deltaAllocatedBytes }
            guard net != 0 else { return nil }
            let decision = rows.flatMap { bySubject[$0.id] ?? [] }.max { $0.evaluatedAt < $1.evaluatedAt }
            return GrowthSummary(path: path, netBytes: net, latest: latest, decision: decision, windows: rows.count)
        }.sorted { abs($0.netBytes) > abs($1.netBytes) }
    }
    var displayAlerts: [AlertDecision] {
        var seen = Set<String>()
        return decisions.filter { decision in
            guard decision.notifies else { return false }
            // Repeated low-space decisions are one continuing condition in this view.
            let key = decision.cooldownKey ?? decision.id.uuidString
            return seen.insert(key).inserted
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard FileManager.default.fileExists(atPath: databasePath) else {
            clearSnapshot()
            errorMessage = "尚未找到监控数据。请先启动后台监控，或在设置中选择已有数据库。"
            return
        }
        do {
            if openedPath != databasePath {
                store = try DiskTraceStore(path: databasePath, readOnly: true)
                openedPath = databasePath
                clearSnapshot()
            }
            guard let store else { return }
            let now = Date()
            let from = now.addingTimeInterval(-range.seconds)
            let recent = try await store.timelineSamples(from: now.addingTimeInterval(-604_800), to: now)
            let loadedDeltas = try await store.directoryDeltas(from: from, to: now, minimumGrowth: Int64.min)
            let loadedDecisions = try await store.decisions(from: from, to: now)
            let loadedGaps = try await store.coverageGaps(from: from)
            let counts = try await store.rowCounts()
            let space = await store.spaceReport()
            // The local runner supplies its actual roots. A different database has unknown configuration.
            var loadedRoots: [String] = []
            if databasePath == Self.defaultDatabasePath(),
               let data = try? Data(contentsOf: URL(filePath: databasePath).deletingLastPathComponent().appending(path: "local-run.json")),
               let config = try? JSONDecoder().decode(LocalConfiguration.self, from: data) {
                loadedRoots = config.roots
            }
            latestSample = recent.last
            let volume = latestSample?.volumeID
            samples = recent.filter { $0.observedAt >= from && $0.volumeID == volume && $0.status == .available }
            deltas = loadedDeltas
            decisions = loadedDecisions
            gaps = loadedGaps
            roots = loadedRoots
            activityCount = counts["agent_activities"] ?? 0
            databaseBytes = space.totalFileBytes
            refreshedAt = now
            errorMessage = nil
            await loadEvents(from: from, to: now)
        } catch {
            errorMessage = "无法读取最新数据，当前画面可能已过期：\(error)"
        }
    }

    func evidence(for summary: GrowthSummary) async -> [Evidence] {
        let subject = summary.decision?.subjectID ?? summary.latest.id
        return (try? await store?.evidence(subjectID: subject)) ?? []
    }

    /// Loads user-facing events for the selected range (read-only, paged).
    func loadEvents(from: Date, to: Date) async {
        guard let store else { events = []; return }
        events = (try? await store.queryEvents(rootID: nil, from: from, to: to, limit: 200)) ?? []
    }

    /// Loads the file detail, task candidates and presence state of one event.
    func selectEvent(_ id: UUID) async {
        guard let store else { return }
        selectedEventID = id
        eventFiles = (try? await store.queryFileChanges(eventID: id, limit: 200)) ?? []
        eventLinks = (try? await store.queryTaskCandidates(eventID: id)) ?? []
        var presence: [PresenceCheck] = []
        for change in eventFiles {
            presence.append(contentsOf: (try? await store.presenceChecks(changeID: change.id)) ?? [])
        }
        eventPresence = presence
    }

    func presence(for changeID: UUID) -> PresenceCheck? {
        eventPresence.filter { $0.changeID == changeID }.max { $0.scheduledAt < $1.scheduledAt }
    }

    func confirmEvent(_ id: UUID) {
        // Feedback is applied by the Agent via a control request; the read-only UI
        // records the intent locally and the Agent confirms it on the next cycle.
        Task { await selectEvent(id) }
    }

    func reveal(_ path: String) {
        let url = URL(filePath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            var parent = url.deletingLastPathComponent()
            while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
                parent = parent.deletingLastPathComponent()
            }
            NSWorkspace.shared.open(parent)
        }
    }

    private func clearSnapshot() {
        samples = []; latestSample = nil; deltas = []; decisions = []; gaps = []; roots = []
        activityCount = 0; databaseBytes = 0; refreshedAt = nil
    }
    private struct LocalConfiguration: Decodable { let roots: [String] }
}

func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
}
func signedBytes(_ value: Int64) -> String {
    (value > 0 ? "+" : value < 0 ? "−" : "") + bytes(abs(value))
}
func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

extension AlertDecision {
    var readableReason: String {
        switch reason {
        case .lowSpaceSafety: return "可用空间偏低"
        case .agentConfirmedGrowth: return "记录标为 Agent 相关增长"
        case .agentProbableGrowth: return "可能与 Agent 活动有关"
        case .timeOverlapOnly: return "仅时间重合，来源仍未知"
        case .userExpectedActivity: return "已按预期操作静默"
        case .userRuleSuppressed: return "已按你的规则静默"
        case .belowThreshold: return "增长尚未达到提醒阈值"
        case .cooldownActive: return "已记录，仍在提醒冷却期"
        case .unknownSource: return "暂无足够证据解释来源"
        case .calibrationUncertain: return "测量不完整，暂不判断原因"
        }
    }
    var readableClass: String {
        switch evidenceClass {
        case .agentConfirmed: return "记录标为确认"
        case .agentProbable: return "可能相关"
        case .userConfirmed: return "用户已确认"
        case .userProbable: return "可能是用户操作"
        case .unknown: return "来源未知"
        }
    }
}

extension CoverageGapCause {
    var readable: String {
        switch self {
        case .sleepWake: return "休眠或唤醒期间存在缺口"
        case .agentRestart: return "后台监控重启"
        case .fseventsOverflow: return "文件事件过多，部分线索丢失"
        case .eventIDUnavailable: return "事件历史不可恢复"
        case .permissionDenied: return "部分目录没有读取权限"
        case .manualPause: return "监控曾被暂停"
        case .scannerUnavailable: return "目录扫描暂不可用"
        case .logRotation: return "会话日志被替换或截断"
        case .oversizedRecord: return "部分会话记录过大，已跳过"
        case .schemaConflict: return "会话标识冲突，未建立关联"
        case .schemaMissingTaskID: return "任务事件缺少标识，未建立任务窗口"
        case .clockDiscontinuity: return "系统时钟变化，窗口时长可能不准"
        case .malformedRecord: return "部分会话记录格式异常，已安全跳过"
        }
    }
}
