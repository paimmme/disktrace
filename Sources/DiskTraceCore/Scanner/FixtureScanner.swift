import Foundation

/// A real, dependency-free filesystem scanner used as the default backend and
/// in tests. It is the single traversal implementation (streaming via
/// `StreamingScanner`); `scan()` is a small compatibility wrapper that collects
/// directory summaries from the same traversal.
public struct FixtureScanner: ScannerBackend {
    public init() {}

    private final class Collector: @unchecked Sendable {
        var directories: [DirectorySize] = []
    }

    public func scan(root: URL, excluding: [String] = []) async throws -> ScanResult {
        let rootPath = FilePaths.canonical(root.path)
        let collector = Collector()
        let completion = try await StreamingScanner().run(
            root: root, excluding: excluding, limits: .default
        ) { entry in
            if case .directory(let summary) = entry {
                collector.directories.append(summary)
            }
        }
        let rootSummary = collector.directories.first { $0.path == rootPath }
        return ScanResult(
            root: rootPath,
            scannedAt: completion.endedAt,
            directories: collector.directories.sorted { $0.path < $1.path },
            totalAllocatedBytes: rootSummary?.allocatedBytes ?? 0,
            totalFileCount: rootSummary?.fileCount ?? 0,
            incomplete: !completion.complete,
            checkpointID: completion.checkpointID)
    }

    public func scanEntries(
        root: URL,
        excluding: [String],
        limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion {
        try await StreamingScanner().run(
            root: root, excluding: excluding, limits: limits, onEntry: onEntry)
    }
}
