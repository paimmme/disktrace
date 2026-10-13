import Darwin
import Foundation

/// Streaming, depth-first filesystem traversal.
///
/// Uses `opendir`/`readdir`/`lstat` one entry at a time — it never builds an
/// array of all URLs in a directory and never holds a dictionary of all files
/// or directories. Each frame keeps only its own accumulated bytes and the
/// totals of completed child subtrees, so memory stays bounded by the depth
/// (≤64 frames), not by the tree size. Directory summaries are emitted when a
/// directory's frame completes.
struct StreamingScanner {
    let probe = MetadataProbe()

    final class Frame {
        let path: String
        let dir: UnsafeMutablePointer<DIR>
        var ownAllocated: Int64 = 0
        var ownFiles: Int = 0
        var subtreeAllocated: Int64 = 0
        var subtreeFiles: Int = 0
        init(path: String, dir: UnsafeMutablePointer<DIR>) {
            self.path = path
            self.dir = dir
        }
    }

    func run(
        root: URL,
        excluding: [String],
        limits: ScanLimits,
        onEntry: @escaping @Sendable (ScanEntry) async throws -> Void
    ) async throws -> ScanCompletion {
        let rootPath = FilePaths.canonical(root.path)
        let excluded = excluding.map { FilePaths.canonical($0) }
        func isExcluded(_ path: String) -> Bool {
            excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        let observedAt = Date()
        let started = Date()
        let deadline = started.addingTimeInterval(limits.maxDuration)
        var entryCount = 0
        var directoryCount = 0
        var complete = true
        var termination: ScanTermination = .completed
        var sizeComplete = true
        var stack: [Frame] = []

        guard let rootDir = opendir(rootPath) else {
            try await onEntry(.inaccessible(path: rootPath, code: errno))
            return ScanCompletion(
                root: rootPath, startedAt: started, endedAt: Date(), complete: false,
                entryCount: 0, directoryCount: 0,
                checkpointID: FSEventCheckpoint.currentEventID(), termination: .storageError)
        }
        stack.append(Frame(path: rootPath, dir: rootDir))
        directoryCount = 1

        while !stack.isEmpty {
            if Task.isCancelled {
                complete = false
                termination = .cancelled
                break
            }
            if Date() > deadline {
                complete = false
                termination = .timeLimited
                break
            }

            let top = stack[stack.count - 1]
            let dirent = readdir(top.dir)
            if dirent == nil {
                closedir(top.dir)
                let totalAllocated = top.ownAllocated + top.subtreeAllocated
                let totalFiles = top.ownFiles + top.subtreeFiles
                try await onEntry(
                    .directory(
                        DirectorySize(
                            path: top.path, allocatedBytes: totalAllocated, fileCount: totalFiles)))
                stack.removeLast()
                if let parent = stack.last {
                    parent.subtreeAllocated += totalAllocated
                    parent.subtreeFiles += totalFiles
                }
                continue
            }

            let name = Self.name(of: dirent!)
            if name.isEmpty || name == "." || name == ".." { continue }
            let childPath = top.path + "/" + name
            if isExcluded(childPath) { continue }

            let metadata: FileMetadata
            switch probe.probe(childPath, observedAt: observedAt) {
            case .success(let value):
                metadata = value
            case .failure(let error):
                complete = false
                step: do {
                    if case .permissionDenied = error {
                        try await onEntry(.inaccessible(path: childPath, code: EACCES))
                        break step
                    }
                }
                continue
            }

            switch metadata.kind {
            case .regularFile:
                if metadata.allocatedBytes == nil { sizeComplete = false }
                top.ownAllocated += metadata.allocatedBytes ?? 0
                top.ownFiles += 1
                entryCount += 1
                try await onEntry(.file(metadata))
            case .directory:
                if stack.count >= limits.maxDepth {
                    complete = false
                    termination = .depthLimited
                    try await onEntry(.inaccessible(path: childPath, code: ELOOP))
                    continue
                }
                guard directoryCount < limits.maxDirectories, let childDir = opendir(childPath) else {
                    complete = false
                    try await onEntry(.inaccessible(path: childPath, code: errno))
                    continue
                }
                directoryCount += 1
                stack.append(Frame(path: childPath, dir: childDir))
            case .symlink, .other:
                // Symlinks are recorded but never followed.
                entryCount += 1
                try await onEntry(.file(metadata))
            }

            if entryCount >= limits.maxEntries {
                complete = false
                termination = .entryLimited
                break
            }
        }

        for frame in stack { closedir(frame.dir) }

        return ScanCompletion(
            root: rootPath, startedAt: started, endedAt: Date(), complete: complete,
            entryCount: entryCount, directoryCount: directoryCount,
            checkpointID: FSEventCheckpoint.currentEventID(), termination: termination,
            sizeComplete: sizeComplete)
    }

    /// Extracts a dirent name without allocating a String for the whole buffer.
    private static func name(of dirent: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: &dirent.pointee.d_name) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}
