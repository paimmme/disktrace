import Foundation

/// One scan backend, per ADR-02. Both the fixture scanner and the (gated)
/// Radix adapter produce the same normalized `ScanResult`.
public protocol ScannerBackend: Sendable {
    func scan(root: URL, excluding: [String]) async throws -> ScanResult
}

public struct ScannerUnavailableError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { "Scanner unavailable: \(reason)" }
}

extension ScannerBackend {
    public func scan(root: URL) async throws -> ScanResult {
        try await scan(root: root, excluding: [])
    }
}
