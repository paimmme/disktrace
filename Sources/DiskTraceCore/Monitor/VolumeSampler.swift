import Darwin
import Foundation

/// Samples volume capacity cheaply. Free space is reported with the
/// purgeable-aware "available for important usage" figure when the filesystem
/// provides it, falling back to `statfs`.
public struct VolumeSampler: Sendable {
    /// Test seam: when set, every sample reports this fixed free space so the
    /// low-space state machine can be exercised without filling a real disk.
    private let fixedFree: Int64?
    private let fixedCapacity: Int64

    public init() {
        fixedFree = nil
        fixedCapacity = 0
    }

    public init(fixedFree: Int64, capacity: Int64 = 1_000_000_000_000) {
        self.fixedFree = fixedFree
        self.fixedCapacity = capacity
    }

    public func sample(url: URL, at date: Date) throws -> VolumeSample {
        try sampleAndMethod(url: url, at: date).0
    }

    /// Returns the sample and which method produced the free-space figure, so
    /// two samples measured differently are never diffed as a precise delta.
    public func sampleAndMethod(url: URL, at date: Date) throws -> (VolumeSample, VolumeMethod) {
        if let fixedFree {
            return (
                VolumeSample(
                    volumeID: "test-volume", observedAt: date, freeBytes: fixedFree,
                    capacityBytes: fixedCapacity, status: .available),
                .importantUsage)
        }
        let standardized = url.standardizedFileURL
        var fs = statfs()
        guard statfs(standardized.path, &fs) == 0 else {
            return (
                VolumeSample(
                    volumeID: standardized.path, observedAt: date,
                    freeBytes: 0, capacityBytes: 0, status: .unavailable),
                .statfsAvailable)
        }
        let volumeID = "\(fs.f_fsid.val.0)-\(fs.f_fsid.val.1)"

        let capacityFromStat = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        let freeFromStat = Int64(fs.f_bavail) * Int64(fs.f_bsize)

        var capacity = capacityFromStat
        var free = freeFromStat
        var status: AvailabilityStatus = .available
        var method: VolumeMethod = .statfsAvailable

        if let values = try? standardized.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            if let total = values.volumeTotalCapacity { capacity = Int64(total) }
            if let available = values.volumeAvailableCapacityForImportantUsage {
                free = available
                method = .importantUsage
            }
        } else if freeFromStat == 0 && capacityFromStat == 0 {
            status = .permissionDenied
        }

        return (
            VolumeSample(
                volumeID: volumeID, observedAt: date,
                freeBytes: max(0, free), capacityBytes: max(0, capacity), status: status),
            method)
    }
}
