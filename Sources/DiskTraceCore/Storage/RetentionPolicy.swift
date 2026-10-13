import Foundation

/// Retention is split into two independent concerns:
///  1. **history pruning** — per-table age rules (and quota-driven row deletion);
///  2. **space reclamation** — WAL checkpoint and incremental vacuum.
///
/// Pruning is driven by deleted row counts and a budget, never by whether the
/// page count happens to drop. User rules and open (unclosed) coverage gaps are
/// always protected.
public struct RetentionPolicy: Sendable {
    public var samplesDetailedDays: Int
    public var samplesHourlyDays: Int
    public var deltasDays: Int
    public var evidenceDays: Int
    public var decisionsDays: Int
    public var activitiesDays: Int
    public var gapsDays: Int
    /// Processed change hints.
    public var hintsDays: Int
    /// Raw file-change detail / event_files.
    public var fileChangesDays: Int
    /// User-facing storage events (aggregate kept longer than detail).
    public var eventsDays: Int
    public var presenceChecksDays: Int
    public var softQuotaBytes: Int64
    /// Upper bound on rows deleted in one pruning pass.
    public var maxRowsPerCycle: Int
    /// Allow `PRAGMA incremental_vacuum` (requires an incremental-auto-vacuum DB).
    public var incrementalVacuum: Bool
    /// Free-space floor below which expensive inventory scans are suspended.
    public var lowSpaceShedBytes: Int64

    public init(
        samplesDetailedDays: Int = 7,
        samplesHourlyDays: Int = 90,
        deltasDays: Int = 90,
        evidenceDays: Int = 7,
        decisionsDays: Int = 90,
        activitiesDays: Int = 90,
        gapsDays: Int = 90,
        hintsDays: Int = 2,
        fileChangesDays: Int = 7,
        eventsDays: Int = 90,
        presenceChecksDays: Int = 7,
        softQuotaBytes: Int64 = 384_000_000,
        maxRowsPerCycle: Int = 20_000,
        incrementalVacuum: Bool = true,
        lowSpaceShedBytes: Int64 = 2_000_000_000
    ) {
        self.samplesDetailedDays = samplesDetailedDays
        self.samplesHourlyDays = samplesHourlyDays
        self.deltasDays = deltasDays
        self.evidenceDays = evidenceDays
        self.decisionsDays = decisionsDays
        self.activitiesDays = activitiesDays
        self.gapsDays = gapsDays
        self.hintsDays = hintsDays
        self.fileChangesDays = fileChangesDays
        self.eventsDays = eventsDays
        self.presenceChecksDays = presenceChecksDays
        self.softQuotaBytes = softQuotaBytes
        self.maxRowsPerCycle = maxRowsPerCycle
        self.incrementalVacuum = incrementalVacuum
        self.lowSpaceShedBytes = lowSpaceShedBytes
    }
}

/// Storage footprint. Reports **both** the in-use page estimate and the real
/// file sizes, since they diverge until space is reclaimed.
public struct SpaceReport: Sendable, Codable, Equatable {
    public var pageCount: Int64
    public var freeListPages: Int64
    public var pageSize: Int64
    /// `(page_count - freelist_count) * page_size` — allocated to live data.
    public var effectiveBytes: Int64
    public var databaseBytes: Int64
    public var walBytes: Int64
    public var shmBytes: Int64

    public init(
        pageCount: Int64 = 0,
        freeListPages: Int64 = 0,
        pageSize: Int64 = 0,
        effectiveBytes: Int64 = 0,
        databaseBytes: Int64 = 0,
        walBytes: Int64 = 0,
        shmBytes: Int64 = 0
    ) {
        self.pageCount = pageCount
        self.freeListPages = freeListPages
        self.pageSize = pageSize
        self.effectiveBytes = effectiveBytes
        self.databaseBytes = databaseBytes
        self.walBytes = walBytes
        self.shmBytes = shmBytes
    }

    public var totalFileBytes: Int64 { databaseBytes + walBytes + shmBytes }
}

public struct RetentionReport: Sendable, Equatable {
    public var evidenceDeleted = 0
    public var deltasDeleted = 0
    public var decisionsDeleted = 0
    public var activitiesDeleted = 0
    public var gapsDeleted = 0
    public var samplesDownsampled = 0
    public var hintsDeleted = 0
    public var fileChangesDeleted = 0
    public var eventsDeleted = 0
    public var eventsMarkedExpired = 0
    public var rowsDeletedForQuota = 0
    public var reclaimedBytes: Int64 = 0
    public var space = SpaceReport()

    public init() {}
}
