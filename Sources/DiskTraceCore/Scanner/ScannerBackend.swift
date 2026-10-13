import Foundation

/// One scan backend, per ADR-02. Both the fixture scanner and the (gated)
/// Radix adapter produce the same normalized types.
public protocol ScannerBackend: Sendable {
    /// Small compatibility interface: walks the same `scanEntries` traversal and
    /// collects directory summaries. Bounded to `ScanLimits.default.maxDirectories`.
    func scan(root: URL, excluding: [String]) async throws -> ScanResult

    /// Streaming traversal with per-entry backpressure. The producer awaits
    /// `onEntry`, so a full consumer buffer blocks production instead of
    /// dropping events; there is no unbounded stream.
    func scanEntries(
        root: URL,
        excluding: [String],
        limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion
}

extension ScannerBackend {
    public func scan(root: URL) async throws -> ScanResult {
        try await scan(root: root, excluding: [])
    }
}

public struct ScannerUnavailableError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { "Scanner unavailable: \(reason)" }
}
