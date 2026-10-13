import Foundation

/// Configuration for reading Codex session metadata. Only non-content fields
/// are ever extracted; see `CodexEventParser`.
public struct CodexIntegrationConfiguration: Sendable {
    public var codexHome: URL
    public var hashWorkingDirectory: Bool
    public var maxFilesPerSync: Int
    /// Upper bound on bytes read per sync, across all files.
    public var byteBudgetPerSync: Int
    /// A single log record larger than this is skipped (and a gap recorded).
    public var maxRecordBytes: Int

    public init(
        codexHome: URL? = nil,
        hashWorkingDirectory: Bool = false,
        maxFilesPerSync: Int = 200,
        byteBudgetPerSync: Int = 512 * 1024,
        maxRecordBytes: Int = 512 * 1024
    ) {
        self.codexHome =
            codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
        self.hashWorkingDirectory = hashWorkingDirectory
        self.maxFilesPerSync = maxFilesPerSync
        self.byteBudgetPerSync = byteBudgetPerSync
        self.maxRecordBytes = maxRecordBytes
    }

    public var sessionsDirectory: URL {
        codexHome.appending(path: "sessions", directoryHint: .isDirectory)
    }
}

/// Chunked, bounded reader for a JSONL session log. It never loads a whole file:
/// it reads at most `budget` bytes from a stored offset, emits only complete
/// lines, and carries a trailing partial line to the next call. An oversized
/// single record is dropped and counted so the caller can record a gap.
enum CodexSessionLog {
    struct Chunk {
        var lines: [Data]
        var readPosition: Int64
        var carry: Data
        var skippedOversized: Int
        var bytesRead: Int

        static let empty = Chunk(
            lines: [], readPosition: 0, carry: Data(), skippedOversized: 0, bytesRead: 0)
    }

    static func read(
        file: URL,
        from position: Int64,
        carry: Data,
        budget: Int,
        maxRecordBytes: Int
    ) throws -> Chunk {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, position)))
        let data = (try handle.read(upToCount: max(1, budget))) ?? Data()
        if data.isEmpty {
            return Chunk(
                lines: [], readPosition: position, carry: carry, skippedOversized: 0, bytesRead: 0)
        }
        let newReadPosition = position + Int64(data.count)

        var buffer = carry
        buffer.append(data)

        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var lastNewlineEnd = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                let line = buffer[lineStart..<index]
                if !line.isEmpty { lines.append(Data(line)) }
                lastNewlineEnd = buffer.index(after: index)
                lineStart = lastNewlineEnd
            }
            index = buffer.index(after: index)
        }

        var newCarry = Data(buffer[lastNewlineEnd..<buffer.endIndex])
        var skipped = 0
        if !newCarry.isEmpty, newCarry.count > maxRecordBytes {
            newCarry = Data()
            skipped = 1
        }

        return Chunk(
            lines: lines, readPosition: newReadPosition, carry: newCarry,
            skippedOversized: skipped, bytesRead: data.count)
    }
}
