import Foundation

/// Configuration for reading Codex session metadata. Only non-content fields
/// are ever extracted; see `CodexEventParser`.
public struct CodexIntegrationConfiguration: Sendable {
    public var codexHome: URL
    public var hashWorkingDirectory: Bool
    public var maxFilesPerSync: Int
    /// Upper bound on bytes read per sync, across all files.
    public var byteBudgetPerSync: Int
    /// Upper bound on bytes read from a single file per sync.
    public var perFileBudgetBytes: Int
    /// A single log record larger than this is skipped (and a gap recorded).
    public var maxRecordBytes: Int
    /// Only enumerate session logs modified within this many days.
    public var lookbackDays: Int
    /// How often the log directory is enumerated.
    public var discoveryInterval: TimeInterval
    /// Hard cap on files held from one enumeration.
    public var maxDiscoveredFiles: Int
    /// When true, also discover Cursor Agent JSONL transcripts under
    /// `cursorProjectsRoot` (read-only metadata; no message bodies).
    public var includeCursorProjects: Bool
    public var cursorProjectsRoot: URL

    public init(
        codexHome: URL? = nil,
        hashWorkingDirectory: Bool = false,
        maxFilesPerSync: Int = 200,
        byteBudgetPerSync: Int = 512 * 1024,
        perFileBudgetBytes: Int = 64 * 1024,
        maxRecordBytes: Int = 512 * 1024,
        lookbackDays: Int = 7,
        discoveryInterval: TimeInterval = 30,
        maxDiscoveredFiles: Int = 2000,
        includeCursorProjects: Bool = true,
        cursorProjectsRoot: URL? = nil
    ) {
        self.codexHome =
            codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
        self.hashWorkingDirectory = hashWorkingDirectory
        self.maxFilesPerSync = maxFilesPerSync
        self.byteBudgetPerSync = byteBudgetPerSync
        self.perFileBudgetBytes = perFileBudgetBytes
        self.maxRecordBytes = maxRecordBytes
        self.lookbackDays = lookbackDays
        self.discoveryInterval = discoveryInterval
        self.maxDiscoveredFiles = maxDiscoveredFiles
        self.includeCursorProjects = includeCursorProjects
        self.cursorProjectsRoot =
            cursorProjectsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".cursor/projects", directoryHint: .isDirectory)
    }

    public var sessionsDirectory: URL {
        codexHome.appending(path: "sessions", directoryHint: .isDirectory)
    }
}

/// Chunked, bounded reader for a JSONL session log. It never loads a whole file:
/// it reads at most `budget` bytes from a read position, emits only complete
/// lines with their absolute offsets, and carries the trailing partial line to
/// the next call. A record (or partial tail) larger than `maxRecordBytes` is
/// dropped and flagged so the caller can record exactly one gap and, if needed,
/// resume discarding after a restart.
enum CodexSessionLog {
    struct Line {
        let data: Data
        /// Absolute file offset where the line starts.
        let startOffset: Int64
        /// Absolute file offset just after the terminating newline.
        let endOffset: Int64
    }

    struct Chunk {
        var lines: [Line]
        /// Absolute offset read up to (bytes fetched), which may include a
        /// partial trailing line.
        var readPosition: Int64
        /// Candidate committed offset: after the last complete line, or advanced
        /// past a dropped oversized record.
        var committedOffset: Int64
        var carry: Data
        /// Absolute offset where `carry` begins.
        var carryStart: Int64
        var oversizedComplete: Int
        var oversizedPartial: Bool
        var bytesRead: Int
    }

    static func read(
        file: URL,
        readPosition: Int64,
        carry: Data,
        carryStart: Int64,
        budget: Int,
        maxRecordBytes: Int
    ) throws -> Chunk {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, readPosition)))
        let data = (try handle.read(upToCount: max(1, budget))) ?? Data()
        if data.isEmpty {
            return Chunk(
                lines: [], readPosition: readPosition, committedOffset: carryStart,
                carry: carry, carryStart: carryStart, oversizedComplete: 0,
                oversizedPartial: false, bytesRead: 0)
        }
        let newReadPosition = readPosition + Int64(data.count)
        var buffer = carry
        buffer.append(data)
        let bufferBase = carryStart

        var lines: [Line] = []
        var oversizedComplete = 0
        var index = buffer.startIndex
        var lineStart = buffer.startIndex
        var lastNewlineEndIndex: Data.Index?
        var lastNewlineEndAbs: Int64?

        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                let line = buffer[lineStart..<index]
                let startAbs = bufferBase + Int64(lineStart - buffer.startIndex)
                let endAbs = bufferBase + Int64(index + 1 - buffer.startIndex)
                if !line.isEmpty {
                    if line.count > maxRecordBytes {
                        oversizedComplete += 1
                    } else {
                        lines.append(Line(data: Data(line), startOffset: startAbs, endOffset: endAbs))
                    }
                }
                lastNewlineEndIndex = buffer.index(after: index)
                lastNewlineEndAbs = endAbs
                lineStart = lastNewlineEndIndex!
            }
            index = buffer.index(after: index)
        }

        let tailStart = lastNewlineEndIndex ?? buffer.startIndex
        let tail = buffer[tailStart...]
        var carryOut: Data
        var carryStartOut: Int64
        var committed: Int64
        var oversizedPartial = false

        if tail.count > maxRecordBytes {
            // A partial record already exceeds the cap: drop it and advance the
            // committed offset past the dropped bytes so a restart resumes after
            // them rather than re-reading a huge prefix.
            carryOut = Data()
            carryStartOut = newReadPosition
            committed = newReadPosition
            oversizedPartial = true
        } else {
            carryOut = Data(tail)
            if let lastNewlineEndAbs {
                committed = lastNewlineEndAbs
                carryStartOut = lastNewlineEndAbs
            } else {
                committed = carryStart
                carryStartOut = carryStart
            }
        }

        return Chunk(
            lines: lines, readPosition: newReadPosition, committedOffset: committed,
            carry: carryOut, carryStart: carryStartOut, oversizedComplete: oversizedComplete,
            oversizedPartial: oversizedPartial, bytesRead: data.count)
    }
}
