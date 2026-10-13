import Foundation

/// A real, dependency-free filesystem scanner used as the default backend and
/// in tests. It computes per-directory **subtree allocated** bytes so that
/// directory deltas are comparable to any other backend.
///
/// It is intentionally conservative: unreadable directories are skipped and
/// mark the result `incomplete` rather than being silently treated as empty.
public struct FixtureScanner: ScannerBackend {
    public init() {}

    public func scan(root: URL, excluding: [String] = []) async throws -> ScanResult {
        let root = root.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try Self.performScan(root: root, excluding: excluding)
        }.value
    }

    static func performScan(root: URL, excluding: [String]) throws -> ScanResult {
        let fileManager = FileManager.default
        // Canonicalize so `/var` vs `/private/var` firmlinks never split a path.
        let rootPath = FilePaths.canonical(root.path)
        let root = URL(filePath: rootPath, directoryHint: .isDirectory)
        let excluded = excluding.map { FilePaths.canonical($0) }
        func isExcluded(_ path: String) -> Bool {
            excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]

        var ownAllocated: [String: Int64] = [:]
        var ownFileCount: [String: Int] = [:]
        var childDirectories: [String: [String]] = [:]
        var directoryPaths: Set<String> = [rootPath]
        var queue: [String] = [rootPath]
        var incomplete = false

        while let directory = queue.popLast() {
            let directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: keys,
                    options: [])
            } catch {
                incomplete = true
                continue
            }
            for child in contents {
                let childPath = child.path
                if isExcluded(childPath) { continue }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else {
                    incomplete = true
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directoryPaths.insert(childPath)
                    childDirectories[directory, default: []].append(childPath)
                    queue.append(childPath)
                } else if values.isRegularFile == true {
                    let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                    ownAllocated[directory, default: 0] += allocated
                    ownFileCount[directory, default: 0] += 1
                }
            }
        }

        // Fold subtree sums bottom-up (deepest paths first).
        let orderedDirectories = directoryPaths.sorted { $0.count > $1.count }
        var subtreeAllocated: [String: Int64] = [:]
        var subtreeFiles: [String: Int] = [:]
        for directory in orderedDirectories {
            var allocated = ownAllocated[directory] ?? 0
            var files = ownFileCount[directory] ?? 0
            for child in childDirectories[directory] ?? [] {
                allocated += subtreeAllocated[child] ?? 0
                files += subtreeFiles[child] ?? 0
            }
            subtreeAllocated[directory] = allocated
            subtreeFiles[directory] = files
        }

        let directories = orderedDirectories
            .sorted()
            .map {
                DirectorySize(
                    path: $0,
                    allocatedBytes: subtreeAllocated[$0] ?? 0,
                    fileCount: subtreeFiles[$0] ?? 0)
            }

        return ScanResult(
            root: rootPath,
            scannedAt: Date(),
            directories: directories,
            totalAllocatedBytes: subtreeAllocated[rootPath] ?? 0,
            totalFileCount: subtreeFiles[rootPath] ?? 0,
            incomplete: incomplete,
            checkpointID: FSEventCheckpoint.currentEventID())
    }
}
