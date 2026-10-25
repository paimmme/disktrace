import Darwin
import Foundation

/// Samples volume capacity cheaply. Free space is reported with the
/// purgeable-aware "available for important usage" figure when the filesystem
/// provides it, falling back to `statfs`.
public struct VolumeSampleDetails: Sendable {
    public let sample: VolumeSample
    public let method: VolumeMethod
    public let statfsFreeBytes: Int64?
    public let importantUsageFreeBytes: Int64?
    public let containerIdentity: String?
}

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
        try sampleDetails(url: url, at: date).sample
    }

    public func sampleAndMethod(url: URL, at date: Date) throws -> (VolumeSample, VolumeMethod) {
        let details = try sampleDetails(url: url, at: date)
        return (details.sample, details.method)
    }

    /// Returns the sample, primary method, and both raw free-space figures when available.
    public func sampleDetails(url: URL, at date: Date) throws -> VolumeSampleDetails {
        if let fixedFree {
            let sample = VolumeSample(
                volumeID: "test-volume", observedAt: date, freeBytes: fixedFree,
                capacityBytes: fixedCapacity, status: .available)
            return VolumeSampleDetails(
                sample: sample, method: .importantUsage, statfsFreeBytes: fixedFree,
                importantUsageFreeBytes: fixedFree, containerIdentity: "test-volume")
        }
        let standardized = url.standardizedFileURL
        var fs = statfs()
        guard statfs(standardized.path, &fs) == 0 else {
            let sample = VolumeSample(
                volumeID: standardized.path, observedAt: date,
                freeBytes: 0, capacityBytes: 0, status: .unavailable)
            return VolumeSampleDetails(
                sample: sample, method: .statfsAvailable, statfsFreeBytes: nil,
                importantUsageFreeBytes: nil, containerIdentity: nil)
        }
        let volumeID = "\(fs.f_fsid.val.0)-\(fs.f_fsid.val.1)"
        let containerIdentity = volumeID

        let capacityFromStat = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        let freeFromStat = Int64(fs.f_bavail) * Int64(fs.f_bsize)

        var capacity = capacityFromStat
        var free = freeFromStat
        var status: AvailabilityStatus = .available
        var method: VolumeMethod = .statfsAvailable
        var importantFree: Int64?

        if let values = try? standardized.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            if let total = values.volumeTotalCapacity { capacity = Int64(total) }
            if let available = values.volumeAvailableCapacityForImportantUsage {
                importantFree = available
                free = available
                method = .importantUsage
            }
        } else if freeFromStat == 0 && capacityFromStat == 0 {
            status = .permissionDenied
        }

        let sample = VolumeSample(
            volumeID: volumeID, observedAt: date,
            freeBytes: max(0, free), capacityBytes: max(0, capacity), status: status)
        return VolumeSampleDetails(
            sample: sample, method: method, statfsFreeBytes: max(0, freeFromStat),
            importantUsageFreeBytes: importantFree, containerIdentity: containerIdentity)
    }
}
