import Foundation

/// Pure hint → file change logic shared by the coordinator and tests.
public enum PathHintProcessor {
    public static let maxPathsPerCycle = 32
    public static let maxPathsPerCycleCritical = 8

    /// Keeps the most specific paths so parent and child hints are not double-counted.
    public static func coalescePaths(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths.map { FilePaths.canonical($0) }))
        let sorted = unique.sorted { $0.count > $1.count }
        var kept: [String] = []
        for path in sorted {
            if kept.contains(where: { $0.hasPrefix(path + "/") }) { continue }
            kept.append(path)
        }
        return kept.sorted()
    }

    public struct Outcome: Sendable {
        public let change: FileChange?
        public let upsert: FileMetadata?
        public let deletePath: String?
    }

    public static func process(
        path: String,
        probe: Result<FileMetadata, ProbeError>,
        previous: FileMetadata?,
        rootID: UUID,
        activeScanID: UUID?,
        windowStart: Date,
        observedAt: Date,
        hintKey: String
    ) -> Outcome {
        let canonical = FilePaths.canonical(path)
        switch probe {
        case .success(let nowMeta):
            guard nowMeta.kind == .regularFile else {
                return Outcome(change: nil, upsert: nil, deletePath: nil)
            }
            if let prev = previous {
                if prev.fileIdentity == nowMeta.fileIdentity {
                    guard let delta = deltaAllocated(before: prev.allocatedBytes, after: nowMeta.allocatedBytes)
                    else {
                        return Outcome(change: nil, upsert: nowMeta, deletePath: nil)
                    }
                    if delta == 0 { return Outcome(change: nil, upsert: nowMeta, deletePath: nil) }
                    let kind: FileChangeKind = delta > 0 ? .grown : .shrunk
                    let change = makeChange(
                        rootID: rootID, scanID: activeScanID, path: canonical,
                        identityBefore: prev.fileIdentity, identityAfter: nowMeta.fileIdentity,
                        kind: kind, before: prev, after: nowMeta, delta: delta,
                        windowStart: windowStart, observedAt: observedAt, hintKey: hintKey,
                        measurement: .measured)
                    return Outcome(change: change, upsert: nowMeta, deletePath: nil)
                }
                let change = makeChange(
                    rootID: rootID, scanID: activeScanID, path: canonical,
                    identityBefore: prev.fileIdentity, identityAfter: nowMeta.fileIdentity,
                    kind: .replaced, before: prev, after: nowMeta,
                    delta: deltaAllocated(before: prev.allocatedBytes, after: nowMeta.allocatedBytes),
                    windowStart: windowStart, observedAt: observedAt, hintKey: hintKey,
                    measurement: .measured)
                return Outcome(change: change, upsert: nowMeta, deletePath: nil)
            }
            let change = makeChange(
                rootID: rootID, scanID: activeScanID, path: canonical,
                identityBefore: nil, identityAfter: nowMeta.fileIdentity, kind: .added,
                before: nil, after: nowMeta, delta: nowMeta.allocatedBytes,
                windowStart: windowStart, observedAt: observedAt, hintKey: hintKey,
                measurement: .beforeUnknown)
            return Outcome(change: change, upsert: nowMeta, deletePath: nil)

        case .failure(.notFound):
            guard let prev = previous else { return Outcome(change: nil, upsert: nil, deletePath: nil) }
            let change = makeChange(
                rootID: rootID, scanID: activeScanID, path: canonical,
                identityBefore: prev.fileIdentity, identityAfter: nil, kind: .removed,
                before: prev, after: nil, delta: prev.allocatedBytes.map { -$0 },
                windowStart: windowStart, observedAt: observedAt, hintKey: hintKey,
                measurement: .measured)
            return Outcome(change: change, upsert: nil, deletePath: canonical)

        case .failure(.permissionDenied):
            return Outcome(change: nil, upsert: nil, deletePath: nil)

        case .failure:
            return Outcome(change: nil, upsert: nil, deletePath: nil)
        }
    }

    private static func deltaAllocated(before: Int64?, after: Int64?) -> Int64? {
        guard let b = before, let a = after else { return nil }
        return a - b
    }

    private static func makeChange(
        rootID: UUID, scanID: UUID?, path: String, identityBefore: String?, identityAfter: String?,
        kind: FileChangeKind, before: FileMetadata?, after: FileMetadata?, delta: Int64?,
        windowStart: Date, observedAt: Date, hintKey: String, measurement: MeasurementState
    ) -> FileChange {
        FileChange(
            id: FileChange.stableID(
                evidenceVersion: EvidenceVersion.current, rootID: rootID,
                identityBefore: identityBefore, identityAfter: identityAfter,
                pathBefore: path, pathAfter: path, locator: "liveHint|\(hintKey)"),
            rootID: rootID, scanID: scanID, pathBefore: path, pathAfter: path,
            identityBefore: identityBefore, identityAfter: identityAfter, kind: kind,
            windowStart: windowStart, windowEnd: observedAt, observedAt: observedAt,
            beforeLogical: before?.logicalBytes, afterLogical: after?.logicalBytes,
            beforeAllocated: before?.allocatedBytes, afterAllocated: after?.allocatedBytes,
            deltaAllocated: delta, measurement: measurement, timing: .liveHintWindow,
            evidenceVersion: EvidenceVersion.current)
    }
}
