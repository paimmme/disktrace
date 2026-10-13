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

    private var changeMonitor: ChangeMonitor?
    private var baseline: [String: ScanResult] = [:]
    private var lastCalibration: Date?
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
        scannerName: String = "fixture"
    ) {
        self.config = config
        self.store = store
        self.scanner = scanner
        self.sampler = sampler
        self.timeSource = timeSource
        self.scannerName = scannerName
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
                lastCalibration = nil  // force recalibration
            }
        }

        // 3. Directory recalibration (periodic, or forced by overflow).
        let calibrationDue =
            lastCalibration == nil
            || now.timeIntervalSince(lastCalibration!) >= config.calibrationInterval
        if calibrationDue {
            for root in config.roots {
                do {
                    let deltas = try await calibrate(root: root, now: now)
                    report.deltas.append(contentsOf: deltas)
                    let decisions = try await evaluate(deltas: deltas, now: now)
                    report.decisions.append(contentsOf: decisions)
                    lastCalibration = now
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
        }

        // 4. Retention.
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

    /// Establishes (or refreshes) the baseline scan for a root without emitting
    /// deltas — used at startup so a first calibration does not look like growth.
    private func calibrateBaseline(root: URL) async {
        do {
            let result = try await scanner.scan(root: root, excluding: config.exclusions)
            baseline[result.root] = result
        } catch {
            let gap = CoverageGap(
                start: timeSource.now(), cause: .scannerUnavailable,
                affectedRoots: [root.path], severity: .medium)
            openGaps.append(gap)
            try? await store.insert(gap)
        }
    }

    private func calibrate(root: URL, now: Date) async throws -> [DirectoryDelta] {
        let result = try await scanner.scan(root: root, excluding: config.exclusions)
        defer { baseline[result.root] = result }
        guard let previous = baseline[result.root] else {
            // First calibration after start(): no delta yet.
            return []
        }
        let windowStart = previous.scannedAt
        var deltas = result.deltas(from: previous, windowStart: windowStart)
        if result.incomplete {
            let gap = CoverageGap(
                start: windowStart, end: result.scannedAt, cause: .permissionDenied,
                affectedRoots: [result.root], severity: .low)
            openGaps.append(gap)
            try? await store.insert(gap)
        }
        // Persist the deltas.
        for delta in deltas {
            try await store.insert(delta)
        }
        // Cap what we return/evaluate to the largest movers to stay bounded.
        if deltas.count > 200 {
            deltas.sort { $0.deltaAllocatedBytes > $1.deltaAllocatedBytes }
            deltas = Array(deltas.prefix(200))
        }
        return deltas
    }

    private func evaluate(deltas: [DirectoryDelta], now: Date) async throws -> [AlertDecision] {
        let rules = try await store.userRules()
        var decisions: [AlertDecision] = []
        for delta in deltas {
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
        return MonitorHealth(
            running: running,
            lastSampleAt: lastSample,
            lastCalibrationAt: lastCalibration,
            baselineEstablished: !baseline.isEmpty,
            openGapCount: openGaps.count,
            databaseBytes: await store.estimatedDatabaseBytes(),
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
