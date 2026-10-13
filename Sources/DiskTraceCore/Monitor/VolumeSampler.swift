import Darwin
import Foundation

/// Samples volume capacity cheaply. Free space is reported with the
/// purgeable-aware "available for important usage" figure when the filesystem
/// provides it, falling back to `statfs`.
public struct VolumeSampler: Sendable {
    public init() {}

    public func sample(url: URL, at date: Date) throws -> VolumeSample {
        let standardized = url.standardizedFileURL
        var fs = statfs()
        guard statfs(standardized.path, &fs) == 0 else {
            return VolumeSample(
                volumeID: standardized.path, observedAt: date,
                freeBytes: 0, capacityBytes: 0, status: .unavailable)
        }
        let volumeID = "\(fs.f_fsid.val.0)-\(fs.f_fsid.val.1)"

        let capacityFromStat = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        let freeFromStat = Int64(fs.f_bavail) * Int64(fs.f_bsize)

        var capacity = capacityFromStat
        var free = freeFromStat
        var status: AvailabilityStatus = .available

        if let values = try? standardized.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            if let total = values.volumeTotalCapacity { capacity = Int64(total) }
            if let available = values.volumeAvailableCapacityForImportantUsage {
                free = available
            }
        } else if freeFromStat == 0 && capacityFromStat == 0 {
            status = .permissionDenied
        }

        return VolumeSample(
            volumeID: volumeID, observedAt: date,
            freeBytes: max(0, free), capacityBytes: max(0, capacity), status: status)
    }
}
