import Foundation

/// Tiered retention: recent detail, then hourly and daily summaries, bounded by
/// a soft storage quota. Aggregation is idempotent and never overwrites a
/// corrupt database — it deletes only reconstructable rows.
public struct RetentionPolicy: Sendable {
    /// Keep raw evidence and per-window deltas this many days.
    public var detailedDays: Int
    /// Keep hourly volume summaries this many days (beyond `detailedDays`).
    public var hourlySummaryDays: Int
    /// Soft cap across the database, WAL and indexes.
    public var softQuotaBytes: Int64

    public init(
        detailedDays: Int = 7,
        hourlySummaryDays: Int = 90,
        softQuotaBytes: Int64 = 1_000_000_000
    ) {
        self.detailedDays = detailedDays
        self.hourlySummaryDays = hourlySummaryDays
        self.softQuotaBytes = softQuotaBytes
    }
}

public struct RetentionReport: Sendable, Equatable {
    public var evidenceDeleted: Int
    public var deltasDeleted: Int
    public var samplesDownsampled: Int
    public var samplesDeletedForQuota: Int
    public var estimatedBytes: Int64

    public init(
        evidenceDeleted: Int = 0,
        deltasDeleted: Int = 0,
        samplesDownsampled: Int = 0,
        samplesDeletedForQuota: Int = 0,
        estimatedBytes: Int64 = 0
    ) {
        self.evidenceDeleted = evidenceDeleted
        self.deltasDeleted = deltasDeleted
        self.samplesDownsampled = samplesDownsampled
        self.samplesDeletedForQuota = samplesDeletedForQuota
        self.estimatedBytes = estimatedBytes
    }
}
