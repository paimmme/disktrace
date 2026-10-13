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
    public var policy: AlertPolicyConfig
    public var retention: RetentionPolicy

    public init(
        roots: [URL],
        exclusions: [String] = [],
        sampleInterval: TimeInterval = 60,
        calibrationInterval: TimeInterval = 900,
        retentionInterval: TimeInterval = 86_400,
        changeCapacity: Int = 512,
        policy: AlertPolicyConfig = AlertPolicyConfig(),
        retention: RetentionPolicy = RetentionPolicy()
    ) {
        self.roots = roots
        self.exclusions = exclusions
        self.sampleInterval = sampleInterval
        self.calibrationInterval = calibrationInterval
        self.retentionInterval = retentionInterval
        self.changeCapacity = changeCapacity
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

/// The single background coordinator (ADR-03): volume sampling, bounded change
/// coalescing, periodic directory recalibration, evidence attribution and alert
/// decisions — all backed by one SQLite store. It never fabricates scan data
/// and records a `CoverageGap` whenever it cannot observe faithfully.
public actor MonitorCoordinator {
    public struct CycleReport: Sendable {
        public var sample: VolumeSample?
        public var changeCount: Int = 0
        public var syncedActivities: Int = 0
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
    /// Per-root scan state. Baselines and calibration times are tracked
    /// independently so one root's success or failure never affects another.
    private struct RootState {
        var baseline: ScanResult?
        var lastCalibration: Date?
    }
    private var rootStates: [String: RootState] = [:]
    private var lastSample: Date?
    private var lastRetention: Date?
    private var running = false
    private var openGaps: [CoverageGap] = []

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
            openGaps.append(
                CoverageGap(
                    start: timeSource.now(), cause: .permissionDenied,
                    affectedRoots: config.roots.map(\.path), severity: .medium))
        }
        changeMonitor = monitor
        running = true

        // Immediate first sample; baseline calibration is progressive.
        if let sample = try? await sampleVolume() {
            _ = try? await recordVolumeDecision(sample, now: timeSource.now())
        }
        for root in config.roots {
            await calibrateBaseline(root: root)
        }
        // Incremental Codex sync runs before attribution so the current cycle
        // has the freshest session metadata available.
        if let activitySync {
            _ = await activitySync.sync(store: store, now: timeSource.now())
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
            let sample = try await sampleVolume()
            report.sample = sample
            let decision = try await recordVolumeDecision(sample, now: now)
            report.decisions.append(decision)
        }

        // 2. Drain and persist change hints; overflow becomes a coverage gap.
        if let output = changeMonitor?.drain() {
            report.changeCount = output.hints.count
            if output.overflowed {
                let gap = CoverageGap(
                    start: now, cause: .fseventsOverflow,
                    affectedRoots: config.roots.map(\.path), severity: .high)
                openGaps.append(gap)
                try await store.insert(gap)
                report.gaps.append(gap)
                // Force recalibration of every root on the next pass.
                for key in rootStates.keys { rootStates[key]?.lastCalibration = nil }
            }
        }

        // 3. Incremental session sync — before directory attribution.
        if let activitySync {
            let synced = await activitySync.sync(store: store, now: now)
            report.syncedActivities = synced.activitiesUpserted
        }

        // 4. Directory recalibration (per root, periodic or forced by overflow).
        for root in config.roots {
            let key = FilePaths.canonical(root.path)
            let last = rootStates[key]?.lastCalibration
            let due = last == nil || now.timeIntervalSince(last!) >= config.calibrationInterval
            guard due else { continue }
            do {
                let deltas = try await calibrate(root: root, now: now)
                report.deltas.append(contentsOf: deltas)
                let decisions = try await evaluate(deltas: deltas, now: now)
                report.decisions.append(contentsOf: decisions)
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
    private func recordVolumeDecision(_ sample: VolumeSample, now: Date) async throws -> AlertDecision {
        let decision = AlertPolicy.evaluate(
            observation: .volume(sample),
            evidence: [],
            userRules: try await store.userRules(),
            config: config.policy,
            now: now)
        try await store.insert(decision)
        return decision
    }

    private func sampleVolume() async throws -> VolumeSample {
        let root = config.roots.first ?? URL(filePath: NSHomeDirectory())
        let sample = try sampler.sample(url: root, at: timeSource.now())
        try await store.insert(sample)
        lastSample = sample.observedAt
        return sample
    }

    /// Establishes the baseline scan for a root without emitting deltas. The
    /// baseline is only accepted when the scan is complete; an incomplete first
    /// scan leaves the root un-baselined until it can be read fully.
    private func calibrateBaseline(root: URL) async {
        do {
            let result = try await scanner.scan(root: root, excluding: config.exclusions)
            if !result.incomplete {
                rootStates[result.root] = RootState(baseline: result, lastCalibration: nil)
            }
        } catch {
            let gap = CoverageGap(
                start: timeSource.now(), cause: .scannerUnavailable,
                affectedRoots: [root.path], severity: .medium)
            openGaps.append(gap)
            try? await store.insert(gap)
        }
    }

    private func calibrate(root: URL, now: Date) async throws -> [DirectoryDelta] {
        let current = try await scanner.scan(root: root, excluding: config.exclusions)
        let key = current.root
        var state = rootStates[key] ?? RootState()
        defer { rootStates[key] = state }

        guard let previous = state.baseline else {
            // First observation: become a baseline only when it is complete.
            if !current.incomplete {
                state.baseline = current
                state.lastCalibration = now
            }
            return []
        }

        // Never derive a trusted delta from an incomplete window: a permission
        // loss must not look like a deletion, nor a recovery like growth.
        if previous.incomplete || current.incomplete {
            let gap = CoverageGap(
                start: previous.scannedAt, end: current.scannedAt, cause: .permissionDenied,
                affectedRoots: [current.root], severity: .medium)
            openGaps.append(gap)
            try await store.insert(gap)
            // Re-baseline only once the scan is complete again; until then the
            // old complete baseline is kept, so recovery diffs against it.
            if !current.incomplete {
                state.baseline = current
                state.lastCalibration = now
            }
            return []
        }

        let deltas = current.deltas(from: previous, windowStart: previous.scannedAt)
        state.baseline = current
        state.lastCalibration = now
        for delta in deltas { try await store.insert(delta) }
        return deltas
    }

    private func evaluate(deltas: [DirectoryDelta], now: Date) async throws -> [AlertDecision] {
        let rules = try await store.userRules()
        // Evaluate only non-overlapping directories so parent and child subtree
        // totals are never double-counted. All deltas remain persisted as facts.
        let candidates = ScanResult.nonOverlapping(deltas)
        var decisions: [AlertDecision] = []
        let bounded = candidates.sorted { abs($0.deltaAllocatedBytes) > abs($1.deltaAllocatedBytes) }
        for delta in bounded.prefix(200) {
            let evidence = try await attribution(for: delta, now: now)
            let key = "dir:\(delta.pathID)"
            let lastAlert = try await store.lastAlertDate(cooldownKey: key)
            let decision = AlertPolicy.evaluate(
                observation: .directory(delta),
                evidence: evidence,
                userRules: rules,
                config: config.policy,
                now: now,
                lastAlertAt: lastAlert)
            try await store.insert(decision)
            decisions.append(decision)
            for item in evidence { try await store.insert(item) }
        }
        return decisions
    }

    /// Deterministic, explainable attribution from minimal, non-content inputs.
    private func attribution(for delta: DirectoryDelta, now: Date) async throws -> [Evidence] {
        var evidence: [Evidence] = []
        let activities = try await store.activities(
            from: delta.windowStart, to: delta.windowEnd)
        for activity in activities {
            if let workingDirectory = activity.workingDirectory,
                delta.pathID == workingDirectory || delta.pathID.hasPrefix(workingDirectory + "/")
            {
                evidence.append(
                    Evidence(
                        subjectID: delta.id,
                        source: .agentTaskEvent,
                        scope: .subtree,
                        strength: .moderate,
                        identity: activity.sessionIDHash,
                        observedAt: delta.windowEnd,
                        limitation:
                            "Agent session time and working directory overlap; not a process-level write observation."
                    ))
            } else {
                evidence.append(
                    Evidence(
                        subjectID: delta.id,
                        source: .agentTaskEvent,
                        scope: .timeWindowOnly,
                        strength: .weak,
                        identity: activity.sessionIDHash,
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

    public func health() async -> MonitorHealth {
        let calibrations = rootStates.values.compactMap(\.lastCalibration)
        return MonitorHealth(
            running: running,
            lastSampleAt: lastSample,
            lastCalibrationAt: calibrations.max(),
            baselineEstablished: rootStates.values.contains { $0.baseline != nil },
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
