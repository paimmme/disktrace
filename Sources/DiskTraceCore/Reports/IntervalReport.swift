import Foundation

public struct IntervalPurposeGroup: Sendable, Hashable, Identifiable {
    public var id: String { purpose.rawValue }
    public let purpose: SoftwarePurpose
    public let netBytes: Int64?
    public let grossAdded: Int64
    public let grossRemoved: Int64
    public let fileCount: Int
    public let topPaths: [String]
}

public struct IntervalVolumeSummary: Sendable {
    public let freeDelta: Int64?
    public let methodComparable: Bool
    public let methodNote: String
    public let firstSampleAt: Date?
    public let lastSampleAt: Date?
}

public struct IntervalSwapSummary: Sendable {
    public let usedDelta: Int64?
    public let fileBytesDelta: Int64?
    public let note: String
}

public struct IntervalExplanationReport: Sendable {
    public let from: Date
    public let to: Date
    public let volume: IntervalVolumeSummary
    public let swap: IntervalSwapSummary
    public let purposeGroups: [IntervalPurposeGroup]
    public let uncoveredBytes: Int64?
    public let uncoveredNote: String
    public let gaps: [CoverageGap]
    public let buildGitCommit: String?
    public let buildSchema: Int?
}

/// Aggregates read-only facts for a user-selected window.
public enum IntervalReportBuilder {
    public static func build(
        samples: [VolumeSample],
        sampleMethods: [UUID: VolumeMethod],
        swapSamples: [SwapSample],
        fileChanges: [FileChange],
        gaps: [CoverageGap],
        from: Date,
        to: Date,
        buildGitCommit: String?,
        buildSchema: Int?
    ) -> IntervalExplanationReport {
        let volume = volumeSummary(samples: samples, methods: sampleMethods)
        let swap = swapSummary(samples: swapSamples)
        let groups = purposeGroups(from: fileChanges)
        let explained = groups.compactMap(\.netBytes).reduce(0, +)
        let swapPart = swap.usedDelta ?? 0
        var uncovered: Int64?
        var uncoveredNote =
            "未覆盖目录、APFS 共享块、采样方法差异或缺少前值的文件变化都可能落在这里；不是“未知=某 Agent”。"
        if let freeDelta = volume.freeDelta, volume.methodComparable {
            let consumed = -freeDelta
            uncovered = consumed - explained - swapPart
            if uncovered == 0 {
                uncoveredNote = "在可比方法下，监控路径与 swap 变化与卷可用空间变化大致对齐；仍不保证 100% 覆盖。"
            }
        } else {
            uncovered = nil
            uncoveredNote = "卷采样方法不一致或样本不足，未计算卷级差额。"
        }
        return IntervalExplanationReport(
            from: from, to: to, volume: volume, swap: swap, purposeGroups: groups,
            uncoveredBytes: uncovered, uncoveredNote: uncoveredNote, gaps: gaps,
            buildGitCommit: buildGitCommit, buildSchema: buildSchema)
    }

    private static func volumeSummary(
        samples: [VolumeSample], methods: [UUID: VolumeMethod]
    ) -> IntervalVolumeSummary {
        guard samples.count >= 2,
            let first = samples.min(by: { $0.observedAt < $1.observedAt }),
            let last = samples.max(by: { $0.observedAt < $1.observedAt })
        else {
            return IntervalVolumeSummary(
                freeDelta: nil, methodComparable: false,
                methodNote: "需要至少两次同卷采样", firstSampleAt: samples.first?.observedAt,
                lastSampleAt: samples.last?.observedAt)
        }
        let m1 = methods[first.id], m2 = methods[last.id]
        let comparable = m1 != nil && m1 == m2
        let delta = comparable ? last.freeBytes - first.freeBytes : nil
        let note =
            comparable
            ? "使用 \(m1!.rawValue) 口径比较首尾可用空间。"
            : "首尾采样方法不同（\(m1?.rawValue ?? "?") vs \(m2?.rawValue ?? "?")），不能当作精确空间突变。"
        return IntervalVolumeSummary(
            freeDelta: delta, methodComparable: comparable, methodNote: note,
            firstSampleAt: first.observedAt, lastSampleAt: last.observedAt)
    }

    private static func swapSummary(samples: [SwapSample]) -> IntervalSwapSummary {
        guard samples.count >= 2,
            let first = samples.min(by: { $0.observedAt < $1.observedAt }),
            let last = samples.max(by: { $0.observedAt < $1.observedAt })
        else {
            return IntervalSwapSummary(
                usedDelta: nil, fileBytesDelta: nil,
                note: SwapSampler().sample().note)
        }
        let usedDelta: Int64?
        if let a = first.swapUsedBytes, let b = last.swapUsedBytes { usedDelta = b - a }
        else { usedDelta = nil }
        let fileDelta: Int64?
        if let a = first.swapFileBytes, let b = last.swapFileBytes { fileDelta = b - a }
        else { fileDelta = nil }
        return IntervalSwapSummary(usedDelta: usedDelta, fileBytesDelta: fileDelta, note: last.note)
    }

    private static func purposeGroups(from changes: [FileChange]) -> [IntervalPurposeGroup] {
        var byPurpose: [SoftwarePurpose: [FileChange]] = [:]
        var seen = Set<UUID>()
        for change in changes {
            guard seen.insert(change.id).inserted else { continue }
            let path = change.pathAfter ?? change.pathBefore ?? ""
            let purpose = SoftwarePurposeClassifier.purpose(for: path)
            byPurpose[purpose, default: []].append(change)
        }
        return SoftwarePurpose.allCases.compactMap { purpose in
            guard purpose != .uncoveredVolume, purpose != .systemSwap else { return nil }
            guard let list = byPurpose[purpose], !list.isEmpty else { return nil }
            let deltas = list.compactMap(\.deltaAllocated)
            let net: Int64? = deltas.count == list.count ? deltas.reduce(0, +) : nil
            let added = deltas.filter { $0 > 0 }.reduce(0, +)
            let removed = deltas.filter { $0 < 0 }.reduce(0, +)
            let tops = list.sorted { abs($0.deltaAllocated ?? 0) > abs($1.deltaAllocated ?? 0) }
                .prefix(5).compactMap { $0.pathAfter ?? $0.pathBefore }
            return IntervalPurposeGroup(
                purpose: purpose, netBytes: net, grossAdded: added, grossRemoved: removed,
                fileCount: list.count, topPaths: tops)
        }.sorted { abs($0.netBytes ?? 0) > abs($1.netBytes ?? 0) }
    }
}
