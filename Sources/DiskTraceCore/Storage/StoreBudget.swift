import Foundation

public enum InventoryBudgetError: Error, Sendable { case exceeded }

extension DiskTraceStore {
    // Refresh once per scan, then account for committed batches. All inventory
    // mutators invalidate this cache; the actor and writer lease serialize writes.
    // Re-reading every path for every 256 entries would make scanning quadratic.
    private func inventoryBudget(scanID: UUID) throws -> (rows: Int, bytes: Int64) {
        if let cache = inventoryBudgetCache, cache.scanID == scanID { return (cache.rows, cache.bytes) }
        let s = try database.prepare("SELECT COUNT(*),COALESCE(SUM((length(CAST(path AS BLOB))+length(file_identity)+128)*2),0)+(SELECT COALESCE(SUM((length(CAST(path AS BLOB))+128)*2),0) FROM scan_directory_summaries) FROM file_inventory;")
        _ = try s.step()
        let value = (rows: s.int(0), bytes: s.int64(1))
        inventoryBudgetCache = (scanID, value.rows, value.bytes)
        return value
    }

    /// One global budget across all roots and active/preparing generations.
    public func stageBudgetedInventory(rootID: UUID, scanID: UUID, files: [FileMetadata],
                                       maximumRows: Int, maximumBytes: Int64,
                                       hardTotalBytes: Int64) throws {
        let used = try inventoryBudget(scanID: scanID)
        let additional = files.reduce(Int64(0)) { $0 + Int64(($1.path.utf8.count + $1.fileIdentity.utf8.count + 128)*2) }
        guard used.rows + files.count <= maximumRows, used.bytes + additional <= maximumBytes,
              ownedStorageBytes() + additional < hardTotalBytes else { throw InventoryBudgetError.exceeded }
        _ = try stageInventory(rootID: rootID, scanID: scanID, files: files)
        inventoryBudgetCache = (scanID, used.rows + files.count, used.bytes + additional)
    }

    public func stageBudgetedDirectories(scanID: UUID, summaries: [DirectorySize], maximumBytes: Int64, hardTotalBytes: Int64) throws {
        let used = try inventoryBudget(scanID: scanID)
        let additional = summaries.reduce(Int64(0)) { $0 + Int64(($1.path.utf8.count + 128)*2) }
        guard used.bytes + additional <= maximumBytes, ownedStorageBytes() + additional < hardTotalBytes else { throw InventoryBudgetError.exceeded }
        _ = try stageDirectorySummaries(scanID: scanID, summaries: summaries)
        inventoryBudgetCache = (scanID, used.rows, used.bytes + additional)
    }

    public func ownedStorageBytes() -> Int64 {
        var total = spaceReport().totalFileBytes
        if let path = databaseFilePath {
            let support = URL(filePath: path).deletingLastPathComponent()
            for name in ["logs", "backups", "commands", "receipts"] {
                if let e = FileManager.default.enumerator(at: support.appendingPathComponent(name), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let url as URL in e {
                        if let v = try? url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]), v.isRegularFile == true {
                            total += Int64(v.fileSize ?? 0)
                        }
                    }
                }
            }
        }
        return total
    }

    public func resetBaseline(rootID: UUID) throws {
        inventoryBudgetCache = nil
        try database.transaction {
            try rawExecute("UPDATE root_health SET active_scan_id=NULL,state='needsRebaseline',inventory_coverage='pending' WHERE root_id=?;", [.text(rootID.uuidString)])
            try rawExecute("DELETE FROM file_inventory WHERE root_id=?;", [.text(rootID.uuidString)])
        }
    }
}
