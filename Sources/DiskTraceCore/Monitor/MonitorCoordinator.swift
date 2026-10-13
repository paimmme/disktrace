import Foundation

public struct MonitorConfig: Sendable {
    public var roots: [URL]
    public var exclusions: [String]
    /// Volume capacity sampling cadence.
    public var sampleInterval: TimeInterval
    /// Directory recalibration cadence.
    public var calibrationInterval: TimeInterval
    /// How often retention is applied.
    public var retentionInterval: TimeInterval
    /// Bound on the coalesced change queue.
    public var changeCapacity: Int
    /// Bound on rows staged into one file-inventory generation.
    public var inventoryRowBudget: Int
    /// Bound on bytes of one file-inventory generation.
    public var inventoryByteBudget: Int64
    public var scanLimits: ScanLimits
    public var configRevision: Int
    public var policy: AlertPolicyConfig
    public var retention: RetentionPolicy

    public init(
        roots: [URL],
        exclusions: [String] = [],
        sampleInterval: TimeInterval = 60,
        calibrationInterval: TimeInterval = 900,
        retentionInterval: TimeInterval = 86_400,
        changeCapacity: Int = 512,
        inventoryRowBudget: Int = 200_000,
        inventoryByteBudget: Int64 = 192_000_000,
        scanLimits: ScanLimits = .default,
        configRevision: Int = 1,
        policy: AlertPolicyConfig = AlertPolicyConfig(),
        retention: RetentionPolicy = RetentionPolicy()
    ) {
        self.roots = roots
        self.exclusions = exclusions
        self.sampleInterval = sampleInterval
        self.calibrationInterval = calibrationInterval
        self.retentionInterval = retentionInterval
        self.changeCapacity = changeCapacity
        self.inventoryRowBudget = inventoryRowBudget
        self.inventoryByteBudget = inventoryByteBudget
        self.scanLimits = scanLimits
        self.configRevision = configRevision
        self.policy = policy
        self.retention = retention
    }
}

public struct MonitorHealth: Sendable, Codable {
    public var running: Bool
    public var lastSampleAt: Date?
    public var lastCalibrationAt: Date?
    public var baselineEstablished: Bool
    public var openGapCount: Int
    public var databaseBytes: Int64
    public var rootCount: Int
    public var scannerBackend: String
}

/// Raised from inside a streaming scan when the staged generation exceeds its
/// row/byte budget; it aborts the traversal before memory or disk grows unbounded.
struct ScanBudgetExceeded: Error {}

/// The single background coordinator (ADR-03): volume sampling, bounded change
/// coalescing, periodic file-inventory recalibration, evidence attribution and
/// alert decisions — all backed by one SQLite store. It never fabricates scan
/// data and records a `CoverageGap` whenever it cannot observe faithfully.
public actor MonitorCoordinator {
    public struct CycleReport: Sendable {
        public var sample: VolumeSample?
        public var changeCount: Int = 0
        public var syncedActivities: Int = 0
        public var fileChangeCount: Int = 0
        public var deltas: [DirectoryDelta] = []
        public var decisions: [AlertDecision] = []
        public var gaps: [CoverageGap] = []
    }

    private let config: MonitorConfig
    private let store: DiskTraceStore
    private let scanner: ScannerBackend
    private let sampler: VolumeSampler
    private let timeSource: TimeSource
    private let scannerName: String
    private let activitySync: AgentActivitySync?

    private var changeMonitor: ChangeMonitor?
    private var lastCalibrationByRoot: [String: Date] = [:]
    private var lastSample: Date?
    private var lastFreeBytes: Int64 = .max
    private var lastRetention: Date?
    private var running = false
    private var openGaps: [CoverageGap] = []
    private var completedFirstCalibration = false

    /// Low-space behaviour ladder. Volume sampling and neutral safety alerts are
    /// never suspended; only the expensive inventory work sheds load.
    enum ResourceMode: String, Sendable {
        case normal
        case constrained
        case critical
    }

    public init(
        config: MonitorConfig,
        store: DiskTraceStore,
        scanner: ScannerBackend = FixtureScanner(),
        sampler: VolumeSampler = VolumeSampler(),
        timeSource: TimeSource = SystemTimeSource(),
        scannerName: String = "fixture",
        activitySync: AgentActivitySync? = nil
    ) {
        self.config = config
        self.store = store
        self.scanner = scanner
        self.sampler = sampler
        self.timeSource = timeSource
        self.scannerName = scannerName
        self.activitySync = activitySync
    }

    public var isRunning: Bool { running }

    public func start() async throws {
        guard !running else { return }
        let monitor = ChangeMonitor(
            roots: config.roots,
            capacity: config.changeCapacity,
            timeSource: timeSource)
        do {
            try monitor.start()
        } catch {
            let gap = CoverageGap(
                start: timeSource.now(), cause: .permissionDenied,
                affectedRoots: config.roots.map(\.path), severity: .medium)
            openGaps.append(gap)
            try? await store.insert(gap)
        }
        changeMonitor = monitor
        running = true

        if let (volume, method) = try? await sampleVolume() {
            _ = try? await recordVolumeDecision(volume, method: method, now: timeSource.now())
        }
        if let activitySync {
            _ = await activitySync.sync(store: store, now: timeSource.now())
        }
        // Establish a baseline generation for each root. A root that already has
        // a valid active generation is *not* rescanned on startup; the periodic
        // calibration picks up any changes as a recovery window instead.
        var startChanges: [FileChange] = []
        for root in config.roots {
            let rootID = MonitoredRoot.stableID(canonicalPath: FilePaths.canonical(root.path))
            if await validActiveGeneration(rootID: rootID) { continue }
            do {
                if let published = try await scanAndPublish(
                    root: root, now: timeSource.now(), timing: .recoveryWindow)
                {
                    startChanges.append(contentsOf: published.fileChanges)
                    _ = try await evaluate(deltas: published.directoryDeltas, now: timeSource.now())
                }
            } catch is ScannerUnavailableError {
                let gap = CoverageGap(
                    start: timeSource.now(), cause: .scannerUnavailable,
                    affectedRoots: [root.path], severity: .medium)
                openGaps.append(gap)
                try? await store.insert(gap)
            } catch {
                let gap = CoverageGap(
                    start: timeSource.now(), cause: .permissionDenied,
                    affectedRoots: [root.path], severity: .medium)
                openGaps.append(gap)
                try? await store.insert(gap)
            }
        }
        // Assemble the changes accumulated since the last run (e.g. after a restart).
        if !startChanges.isEmpty {
            _ = try? await assembleAndEvaluate(changes: startChanges, now: timeSource.now())
        }
        try await store.setState("running", "true", at: timeSource.now())
    }

    public func stop() async {
        changeMonitor?.stop()
        changeMonitor = nil
        running = false
        try? await store.setState("running", "false", at: timeSource.now())
    }

    /// One monitoring cycle. Safe to call on a timer; returns what it recorded.
    @discardableResult
    public func runOnce() async throws -> CycleReport {
        let now = timeSource.now()
        var report = CycleReport()

        // 1. Volume sampling (never blocked by attribution work).
        if lastSample == nil || now.timeIntervalSince(lastSample!) >= config.sampleInterval {
            if let (sample, method) = try? await sampleVolume() {
                report.sample = sample
                let decision = try await recordVolumeDecision(sample, method: method, now: now)
                report.decisions.append(decision)
            }
        }

        // 2. Drain and persist change hints; overflow becomes a coverage gap.
        if let output = changeMonitor?.drain() {
            report.changeCount = output.hints.count
            try await persistHints(output.hints, at: now)
            if output.overflowed {
                let gap = CoverageGap(
                    start: now, cause: .fseventsOverflow,
                    affectedRoots: config.roots.map(\.path), severity: .high)
                openGaps.append(gap)
                try await store.insert(gap)
                report.gaps.append(gap)
                lastCalibrationByRoot.removeAll()  // force recalibration of every root
            }
        }

        // 3. Incremental session sync — before directory attribution.
        if let activitySync {
            let synced = await activitySync.sync(store: store, now: now)
            report.syncedActivities = synced.activitiesUpserted
        }

        // 4. File-inventory recalibration (per root, periodic or forced).
        var publishedChanges: [FileChange] = []
        let mode = resourceMode()
        if mode == .normal {
            let timing: TimingPrecision = completedFirstCalibration ? .scanWindow : .recoveryWindow
            for root in config.roots {
                let key = FilePaths.canonical(root.path)
                let last = lastCalibrationByRoot[key]
                let due = last == nil || now.timeIntervalSince(last!) >= config.calibrationInterval
                guard due else { continue }
                do {
                    if let published = try await scanAndPublish(root: root, now: now, timing: timing) {
                        report.fileChangeCount += published.fileChanges.count
                        publishedChanges.append(contentsOf: published.fileChanges)
                        report.deltas.append(contentsOf: published.directoryDeltas)
                        report.decisions.append(contentsOf: try await evaluate(deltas: published.directoryDeltas, now: now))
                    }
                    lastCalibrationByRoot[key] = now
                } catch let error as ScannerUnavailableError {
                    let gap = CoverageGap(
                        start: now, cause: .scannerUnavailable,
                        affectedRoots: [root.path], severity: .medium)
                    openGaps.append(gap)
                    try await store.insert(gap)
                    report.gaps.append(gap)
                    _ = error
                }
            }
            completedFirstCalibration = true
        } else {
            // Constrained / Critical: the most valuable facts in low space are
            // the volume samples and the neutral safety alert, which continue.
            // Inventory staging is suspended and each root is marked quota-limited
            // so the health view never claims `ready`. This is a bounded, explicit
            // degradation — not a silent gap.
            let roots = (try? await store.roots()) ?? []
            for root in roots {
                try? await store.markRootState(rootID: root.id, state: .quotaLimited)
            }
            report.gaps.append(
                CoverageGap(
                    start: now, cause: .permissionDenied,
                    affectedRoots: config.roots.map(\.path), severity: .low))
        }

        // 4b. Assemble user-facing events from file changes, persist, evaluate.
        if !publishedChanges.isEmpty {
            report.decisions.append(contentsOf: try await assembleAndEvaluate(changes: publishedChanges, now: now))
        }
        try await runPresenceChecks(now: now)

        // 5. Retention.
        if lastRetention == nil
            || now.timeIntervalSince(lastRetention!) >= config.retentionInterval
        {
            _ = try await store.applyRetention(config.retention, now: now)
            lastRetention = now
        }

        return report
    }

    @discardableResult
    private func recordVolumeDecision(
        _ sample: VolumeSample, method: VolumeMethod, now: Date
    ) async throws -> AlertDecision {
        try await store.insert(sample, method: method)
        let decision = AlertPolicy.evaluate(
            observation: .volume(sample),
            evidence: [],
            userRules: try await store.userRules(),
            config: config.policy,
            now: now)
        try await store.insert(decision)
        await enqueueIfNeeded(decision, now: now)
        return decision
    }

    /// Writes a pending outbox item for a notifying decision. Delivery happens
    /// in the agent (independently of any UI window).
    private func enqueueIfNeeded(_ decision: AlertDecision, now: Date) async {
        guard decision.notifies else { return }
        let category: NotificationCategory
        switch decision.action {
        case .notifyAgentAnomaly: category = .agentGrowth
        case .notifySafetyLowSpace: category = .lowSpaceSafety
        case .silent: return
        }
        let item = OutboxItem(
            id: OutboxItem.stableID(decisionID: decision.id), decisionID: decision.id,
            eventID: category == .agentGrowth ? decision.subjectID : nil, category: category,
            state: .pending, createdAt: now,
            expiresAt: now.addingTimeInterval(NotificationPolicy.expiry(for: category)))
        try? await store.enqueueNotification(item)
    }

    private func sampleVolume() async throws -> (VolumeSample, VolumeMethod) {
        let root = config.roots.first ?? URL(filePath: NSHomeDirectory())
        let result = try sampler.sampleAndMethod(url: root, at: timeSource.now())
        lastSample = result.0.observedAt
        if result.0.status == .available { lastFreeBytes = result.0.freeBytes }
        return result
    }

    // MARK: - Streaming scan → staged generation → publish

    private final class ScanStager: @unchecked Sendable {
        let store: DiskTraceStore
        let rootID: UUID
        let scanID: UUID
        let batchSize: Int
        let rowBudget: Int
        var files: [FileMetadata] = []
        var directories: [DirectorySize] = []
        var rows = 0

        init(store: DiskTraceStore, rootID: UUID, scanID: UUID, batchSize: Int, rowBudget: Int) {
            self.store = store
            self.rootID = rootID
            self.scanID = scanID
            self.batchSize = batchSize
            self.rowBudget = rowBudget
        }

        func add(_ entry: ScanEntry) async throws {
            switch entry {
            case .file(let metadata): files.append(metadata)
            case .directory(let summary): directories.append(summary)
            case .inaccessible: return
            }
            if files.count >= batchSize { try await flushFiles() }
            if directories.count >= batchSize { try await flushDirectories() }
        }

        func flushFiles() async throws {
            guard !files.isEmpty else { return }
            rows += files.count
            let batch = files
            files.removeAll(keepingCapacity: true)
            try await store.stageInventory(rootID: rootID, scanID: scanID, files: batch)
            if rows > rowBudget { throw ScanBudgetExceeded() }
        }

        func flushDirectories() async throws {
            guard !directories.isEmpty else { return }
            let batch = directories
            directories.removeAll(keepingCapacity: true)
            try await store.stageDirectorySummaries(scanID: scanID, summaries: batch)
        }

        func flush() async throws {
            try await flushFiles()
            try await flushDirectories()
        }
    }

    private func scanAndPublish(
        root: URL, now: Date, timing: TimingPrecision = .scanWindow
    ) async throws -> PublishResult? {
        let canonical = FilePaths.canonical(root.path)
        let volumeID = (try? sampler.sample(url: root, at: now))?.volumeID
        let rootRecord = try await store.ensureRoot(
            canonicalPath: canonical, volumeID: volumeID,
            configRevision: config.configRevision, at: now)
        let scanID = try await store.beginScan(rootID: rootRecord.id, startEventID: nil, at: now)
        let stager = ScanStager(
            store: store, rootID: rootRecord.id, scanID: scanID,
            batchSize: config.scanLimits.batchSize, rowBudget: config.inventoryRowBudget)
        do {
            let completion = try await scanner.scanEntries(
                root: root, excluding: config.exclusions, limits: config.scanLimits
            ) { entry in
                try await stager.add(entry)
            }
            try await stager.flush()
            if completion.complete {
                return try await store.publishScan(
                    rootID: rootRecord.id, scanID: scanID, at: timeSource.now(), complete: true,
                    timing: timing, sizeComplete: completion.sizeComplete)
            }
            let gap = CoverageGap(
                start: now, cause: .permissionDenied, affectedRoots: [canonical], severity: .medium)
            openGaps.append(gap)
            try? await store.insert(gap)
            try await store.failScan(
                rootID: rootRecord.id, scanID: scanID, reason: completion.termination.rawValue,
                state: .needsRebaseline, at: timeSource.now())
            return nil
        } catch is ScanBudgetExceeded {
            let gap = CoverageGap(
                start: now, cause: .permissionDenied, affectedRoots: [canonical], severity: .medium)
            openGaps.append(gap)
            try? await store.insert(gap)
            try? await store.failScan(
                rootID: rootRecord.id, scanID: scanID, reason: "quotaLimited",
                state: .quotaLimited, at: timeSource.now())
            return nil
        }
    }

    private func persistHints(_ hints: [ChangeHint], at now: Date) async throws {
        guard !hints.isEmpty else { return }
        let roots = (try? await store.roots()) ?? []
        guard !roots.isEmpty else { return }
        var byRoot: [UUID: [ChangeHint]] = [:]
        for hint in hints {
            guard
                let match = roots.first(where: {
                    hint.path == $0.canonicalPath || hint.path.hasPrefix($0.canonicalPath + "/")
                })
            else { continue }
            byRoot[match.id, default: []].append(hint)
        }
        let checkpoint = hints.map(\.eventID).max() ?? 0
        for (rootID, rootHints) in byRoot {
            let root = roots.first { $0.id == rootID }
            try await store.persistHints(
                rootID: rootID, volumeID: root?.volumeID ?? "unknown", eventID: checkpoint,
                hints: rootHints, checkpoint: checkpoint,
                volumeIdentity: root?.volumeID ?? "unknown", at: now)
        }
    }

    private func evaluate(deltas: [DirectoryDelta], now: Date) async throws -> [AlertDecision] {
        let rules = try await store.userRules()
        // Attribute each concrete scope independently (ancestors are not
        // filtered out before attribution); display dedups later.
        let bounded = deltas.sorted { abs($0.deltaAllocatedBytes) > abs($1.deltaAllocatedBytes) }
        var decisions: [AlertDecision] = []
        for delta in bounded.prefix(200) {
            let evidence = try await attribution(for: delta, now: now)
            let key = "dir:\(delta.pathID)"
            let lastAlert = try await store.lastAlertDate(cooldownKey: key)
            let decision = AlertPolicy.evaluate(
                observation: .directory(delta), evidence: evidence, userRules: rules,
                config: config.policy, now: now, lastAlertAt: lastAlert)
            try await store.insert(decision)
            await enqueueIfNeeded(decision, now: now)
            decisions.append(decision)
            for item in evidence { try await store.insert(item) }
        }
        return decisions
    }

    /// Deterministic, explainable attribution from minimal, non-content inputs.
    private func attribution(for delta: DirectoryDelta, now: Date) async throws -> [Evidence] {
        var evidence: [Evidence] = []
        let activities = try await store.activities(from: delta.windowStart, to: delta.windowEnd)
        for activity in activities {
            if let workingDirectory = activity.workingDirectory,
                delta.pathID == workingDirectory || delta.pathID.hasPrefix(workingDirectory + "/")
            {
                let bounded = activity.windowIsTaskBounded
                evidence.append(
                    Evidence(
                        subjectID: delta.id, source: .agentTaskEvent,
                        scope: .subtree, strength: bounded ? .moderate : .weak,
                        identity: activity.sessionIDHash, observedAt: delta.windowEnd,
                        limitation: bounded
                            ? "Bounded task window overlaps this scope; not a process-level write observation."
                            : "Open/approximate task window; not a confident writer attribution."))
            } else {
                evidence.append(
                    Evidence(
                        subjectID: delta.id, source: .agentTaskEvent, scope: .timeWindowOnly,
                        strength: .weak, identity: activity.sessionIDHash,
                        observedAt: delta.windowEnd,
                        limitation: "Time overlap only; cannot attribute this change to the agent."))
            }
        }
        if evidence.isEmpty {
            let path = delta.pathID
            if path.contains("/node_modules/") {
                evidence.append(
                    Evidence(
                        subjectID: delta.id, source: .directoryNameHint, scope: .directoryName,
                        strength: .weak, observedAt: delta.windowEnd,
                        limitation: "Directory name is suggestive only, not proof of a writer."))
            } else if path.contains("/Library/Caches/") || path.contains("/.cache/") {
                evidence.append(
                    Evidence(
                        subjectID: delta.id, source: .cacheDirectoryHint, scope: .directoryName,
                        strength: .weak, observedAt: delta.windowEnd,
                        limitation: "Cache directory match is not a writer attribution."))
            }
        }
        return evidence
    }

    // MARK: - Event assembly, presence checks

    private func assembleAndEvaluate(changes: [FileChange], now: Date) async throws -> [AlertDecision] {
        let roots = (try? await store.roots()) ?? []
        guard !roots.isEmpty else { return [] }
        let rootMap = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.canonicalPath) })
        let activities = (try? await store.activities(from: now.addingTimeInterval(-86_400), to: now)) ?? []
        let activityMap = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        let windows = (try? await store.taskWindows(activeSince: now.addingTimeInterval(-86_400))) ?? []

        let assembled = EventAssembler.assemble(
            changes: changes, windows: windows, activities: activityMap, roots: rootMap,
            configRevision: config.configRevision, now: now)
        try await store.upsertEvents(assembled, at: now)

        let rules = try await store.userRules()
        var decisions: [AlertDecision] = []
        for item in assembled {
            let key = "event:\(item.event.scopePath)"
            let lastAlert = try await store.lastAlertDate(cooldownKey: key)
            let decision = AlertPolicy.evaluate(
                observation: .event(item.event), evidence: [], userRules: rules,
                config: config.policy, now: now, lastAlertAt: lastAlert)
            try await store.insert(decision)
            await enqueueIfNeeded(decision, now: now)
            decisions.append(decision)

            // Schedule presence checks for linked added/grown files.
            let linked = item.links.contains { $0.state == .pathCandidate }
            if linked {
                for change in changes where item.changeIDs.contains(change.id) {
                    guard change.kind == .added || change.kind == .grown else { continue }
                    try? await store.schedulePresence(
                        changeID: change.id, at: now.addingTimeInterval(600))
                    try? await store.schedulePresence(
                        changeID: change.id, at: now.addingTimeInterval(86_400))
                }
            }
        }
        return decisions
    }

    /// Runs due presence checks. A missing path is reported as "no longer exists"
    /// (never "cleaned" or "safe to delete"); a changed identity is "replaced".
    private func runPresenceChecks(now: Date) async throws {
        let probe = MetadataProbe()
        let due = (try? await store.duePresenceChecks(now: now)) ?? []
        for check in due {
            var result = PresenceCheck(
                changeID: check.changeID, scheduledAt: check.scheduledAt, checkedAt: now,
                result: .unknown, currentIdentity: nil, currentAllocated: nil)
            if let change = try? await store.fileChange(id: check.changeID),
                let path = change.pathAfter ?? change.pathBefore
            {
                switch probe.probe(path, observedAt: now) {
                case .success(let metadata):
                    result = PresenceCheck(
                        changeID: check.changeID, scheduledAt: check.scheduledAt, checkedAt: now,
                        result: metadata.fileIdentity == change.identityAfter ? .present : .replaced,
                        currentIdentity: metadata.fileIdentity,
                        currentAllocated: metadata.allocatedBytes)
                case .failure(.notFound):
                    result = PresenceCheck(
                        changeID: check.changeID, scheduledAt: check.scheduledAt, checkedAt: now,
                        result: .missing, currentIdentity: nil, currentAllocated: nil)
                case .failure:
                    result = PresenceCheck(
                        changeID: check.changeID, scheduledAt: check.scheduledAt, checkedAt: now,
                        result: .unknown, currentIdentity: nil, currentAllocated: nil)
                }
            }
            try? await store.recordPresence(result)
        }
    }

    /// Low-space ladder derived from the last observed free space.
    private func resourceMode() -> ResourceMode {
        guard lastFreeBytes != .max else { return .normal }
        if lastFreeBytes < config.retention.lowSpaceShedBytes / 2 { return .critical }
        if lastFreeBytes < config.retention.lowSpaceShedBytes { return .constrained }
        return .normal
    }

    /// True when a root already has an active generation owned by it, so startup
    /// can trust it as a historical baseline instead of rescanning unconditionally.
    private func validActiveGeneration(rootID: UUID) async -> Bool {
        guard let health = try? await store.rootHealth(rootID: rootID),
            let active = health.activeScanID
        else { return false }
        return (try? await store.scanOwner(scanID: active)) == rootID
    }

    public func health() async -> MonitorHealth {
        let calibrations = Array(lastCalibrationByRoot.values)
        let roots = (try? await store.roots()) ?? []
        var ready = false
        for root in roots {
            if let health = try? await store.rootHealth(rootID: root.id), health.state == .ready {
                ready = true
            }
        }
        return MonitorHealth(
            running: running,
            lastSampleAt: lastSample,
            lastCalibrationAt: calibrations.max(),
            baselineEstablished: ready,
            openGapCount: openGaps.count,
            databaseBytes: await store.spaceReport().effectiveBytes,
            rootCount: config.roots.count,
            scannerBackend: scannerName)
    }

    /// Test/diagnostic hook: number of persisted rows.
    public func rowCounts() async -> [String: Int] {
        (try? await store.rowCounts()) ?? [:]
    }

    /// Records a coverage gap directly (e.g. on sleep/wake from the app layer).
    public func recordGap(_ cause: CoverageGapCause, severity: CoverageSeverity) async {
        let gap = CoverageGap(
            start: timeSource.now(), cause: cause,
            affectedRoots: config.roots.map(\.path), severity: severity)
        openGaps.append(gap)
        try? await store.insert(gap)
    }
}
