import Foundation

public enum CoverageGapCause: String, Codable, Sendable {
    case sleepWake
    case agentRestart
    case fseventsOverflow
    case eventIDUnavailable
    case permissionDenied
    case manualPause
    case scannerUnavailable
    /// A session log was truncated, replaced or rotated, so the sync cursor was
    /// reset and some appended content may not have been observed.
    case logRotation
    /// A session log record exceeded the per-record size cap and was skipped.
    case oversizedRecord
    /// `session_meta` carried conflicting `id`/`session_id`, so linking is refused.
    case schemaConflict
    /// A task lifecycle event had no usable task/turn id.
    case schemaMissingTaskID
    /// A clock discontinuity was observed; window durations may be unreliable.
    case clockDiscontinuity
    /// A log line could not be parsed (malformed JSON); it was skipped safely.
    case malformedRecord
}

public enum CoverageSeverity: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// An interval during which monitoring could not fully observe changes.
/// Gaps are surfaced, never silently papered over with a reconstructed history.
public struct CoverageGap: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let start: Date
    public let end: Date?
    public let cause: CoverageGapCause
    public let affectedRoots: [String]
    public let severity: CoverageSeverity

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date? = nil,
        cause: CoverageGapCause,
        affectedRoots: [String],
        severity: CoverageSeverity
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.cause = cause
        self.affectedRoots = affectedRoots
        self.severity = severity
    }
}
