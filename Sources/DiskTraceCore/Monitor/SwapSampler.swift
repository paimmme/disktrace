import Darwin
import Foundation

public struct SwapSample: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let observedAt: Date
    /// Kernel-reported swap in use (not attributable to a single app).
    public let swapUsedBytes: Int64?
    /// On-disk swap file allocation under `/private/var/vm` when readable.
    public let swapFileBytes: Int64?
    public let note: String

    public init(
        id: UUID = UUID(), observedAt: Date, swapUsedBytes: Int64?, swapFileBytes: Int64?,
        note: String
    ) {
        self.id = id
        self.observedAt = observedAt
        self.swapUsedBytes = swapUsedBytes
        self.swapFileBytes = swapFileBytes
        self.note = note
    }
}

/// Lightweight swap totals — system scope only, never Agent-attributed.
public struct SwapSampler: Sendable {
    public init() {}

    public func sample(at date: Date = Date()) -> SwapSample {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let used: Int64?
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            used = Int64(usage.xsu_used)
        } else {
            used = nil
        }
        let fileBytes = Self.swapFileAllocationBytes()
        let note =
            fileBytes == nil && used == nil
            ? "无法读取交换区指标"
            : "系统交换使用量；与 Data 卷可用空间不可直接核销，也不归属某个 Agent。"
        return SwapSample(
            observedAt: date, swapUsedBytes: used, swapFileBytes: fileBytes, note: note)
    }

    private static func swapFileAllocationBytes() -> Int64? {
        let vm = URL(filePath: "/private/var/vm")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: vm, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        else { return nil }
        var total: Int64 = 0
        var any = false
        for url in items where url.lastPathComponent.hasPrefix("swapfile") {
            any = true
            if let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                let b = values.totalFileAllocatedSize ?? values.fileAllocatedSize
            {
                total += Int64(b)
            }
        }
        return any ? total : nil
    }
}
