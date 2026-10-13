import Darwin
import Foundation
import Testing
@testable import DiskTraceCore

private actor ScanGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func block() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct BlockingScanner: ScannerBackend {
    let gate: ScanGate
    func scan(root: URL, excluding: [String]) async throws -> ScanResult { throw ScannerUnavailableError(reason: "not used") }
    func scanEntries(root: URL, excluding: [String], limits: ScanLimits,
                     onEntry: @escaping @Sendable (ScanEntry) async throws -> Void) async throws -> ScanCompletion {
        await gate.block()
        return ScanCompletion(root: root.path, startedAt: Date(), endedAt: Date(), complete: true, entryCount: 0, directoryCount: 0, checkpointID: 0, termination: .completed)
    }
}
@Suite("Runtime repair safety") struct RuntimeRepairTests {
    func temporary() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("disktrace-runtime-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    @Test func capacityContinuesWhileScanIsBlocked() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ScanGate(), store = try DiskTraceStore.inMemory(), clock = ManualTimeSource(Date())
        let co = MonitorCoordinator(config: .init(roots:[dir], sampleInterval:60), store:store,
            scanner: BlockingScanner(gate:gate), sampler:VolumeSampler(fixedFree:500_000_000_000), timeSource:clock)
        let startup = Task { try await co.start() }
        await gate.waitUntilEntered()
        #expect(await gate.entered)
        clock.advance(by:120)
        try await co.sampleIfDue()
        let count = try await store.rowCounts()["volume_samples"] ?? 0
        #expect(count >= 2)
        await gate.release(); try await startup.value; await co.stop()
    }
    @Test func prePauseScanCannotPublishAfterResume() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ScanGate(), store = try DiskTraceStore.inMemory()
        let co = MonitorCoordinator(config:.init(roots:[dir]),store:store,scanner:BlockingScanner(gate:gate),sampler:VolumeSampler(fixedFree:500_000_000_000))
        let startup = Task { try await co.start() }
        await gate.waitUntilEntered()
        try await co.setPaused(true); try await co.setPaused(false)
        await gate.release(); try await startup.value
        let health = try await store.rootHealth(rootID:MonitoredRoot.stableID(canonicalPath:FilePaths.canonical(dir.path)))
        #expect(health?.activeScanID == nil)
        #expect(health?.state != .ready)
        await co.stop()
    }
    @Test func globalInventoryBudgetIncludesOtherRootAndOldGeneration() async throws {
        let store = try DiskTraceStore.inMemory(), date = Date()
        let a = try await store.ensureRoot(canonicalPath:"/a",volumeID:nil,configRevision:1,at:date)
        let b = try await store.ensureRoot(canonicalPath:"/b",volumeID:nil,configRevision:1,at:date)
        let sa = try await store.beginScan(rootID:a.id,startEventID:nil,at:date)
        let sb = try await store.beginScan(rootID:b.id,startEventID:nil,at:date)
        func file(_ path:String) -> FileMetadata { .init(path:path,fileIdentity:path,kind:.regularFile,logicalBytes:1,allocatedBytes:1,modifiedAt:nil,birthAt:nil,observedAt:date,linkCount:1) }
        try await store.stageBudgetedInventory(rootID:a.id,scanID:sa,files:[file("/a/x")],maximumRows:1,maximumBytes:10000,hardTotalBytes:10_000_000)
        await #expect(throws:InventoryBudgetError.self) {
            try await store.stageBudgetedInventory(rootID:b.id,scanID:sb,files:[file("/b/x")],maximumRows:1,maximumBytes:10000,hardTotalBytes:10_000_000)
        }
        await #expect(throws:InventoryBudgetError.self) {
            try await store.stageBudgetedInventory(rootID:b.id,scanID:sb,files:[file("/b/x")],maximumRows:100,maximumBytes:1,hardTotalBytes:10_000_000)
        }
        _ = try await store.publishScan(rootID:a.id,scanID:sa,at:date,complete:true)
        let newA = try await store.beginScan(rootID:a.id,startEventID:nil,at:date)
        await #expect(throws:InventoryBudgetError.self) {
            try await store.stageBudgetedInventory(rootID:a.id,scanID:newA,files:[file("/a/x")],maximumRows:1,maximumBytes:10000,hardTotalBytes:10_000_000)
        }
        #expect(try await store.inventoryCount(rootID:a.id,scanID:sa) == 1)
        #expect(try await store.inventoryCount(rootID:b.id,scanID:sb) == 0)
    }
    @Test func budgetCacheIsInvalidatedByDirectStaging() async throws {
        let store = try DiskTraceStore.inMemory(), t = Date()
        let root = try await store.ensureRoot(canonicalPath:"/r",volumeID:nil,configRevision:1,at:t)
        let scan = try await store.beginScan(rootID:root.id,startEventID:nil,at:t)
        func file(_ path:String) -> FileMetadata { .init(path:path,fileIdentity:path,kind:.regularFile,logicalBytes:1,allocatedBytes:1,modifiedAt:nil,birthAt:nil,observedAt:t,linkCount:1) }
        try await store.stageBudgetedInventory(rootID:root.id,scanID:scan,files:[file("/r/a")],maximumRows:2,maximumBytes:10000,hardTotalBytes:10_000_000)
        _ = try await store.stageInventory(rootID:root.id,scanID:scan,files:[file("/r/b")])
        await #expect(throws:InventoryBudgetError.self) {
            try await store.stageBudgetedInventory(rootID:root.id,scanID:scan,files:[file("/r/c")],maximumRows:2,maximumBytes:10000,hardTotalBytes:10_000_000)
        }
        #expect(try await store.inventoryCount(rootID:root.id,scanID:scan) == 2)
    }
    @Test func lockRejectsSecondWriterAndSymlink() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("writer.lock").path
        let first = try SingleWriterLock(path:path)
        #expect(throws:SingleWriterLockError.self) { _ = try SingleWriterLock(path:path) }
        first.release()
        let target = dir.appendingPathComponent("precious");try Data("retain".utf8).write(to:target)
        let link = dir.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        #expect(throws:SingleWriterLockError.self) { _ = try SingleWriterLock(path:link.path) }
        #expect(try String(contentsOf:target,encoding:.utf8) == "retain")
    }
    @Test func inboxExpiresAndIgnoresSymlink() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try DiskTraceStore.inMemory(), co = MonitorCoordinator(config:.init(roots:[]),store:store)
        let expired = ControlRequest(command:.pause,now:Date().addingTimeInterval(-600))
        try ControlFiles.submit(expired,support:dir)
        let id = UUID(), target = dir.appendingPathComponent("precious")
        try Data("retain".utf8).write(to:target)
        let link = dir.appendingPathComponent("commands/"+id.uuidString+".json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        await ControlInbox(support:dir).process(store:store,coordinator:co,native:{_ in "unused"})
        #expect(ControlFiles.receipt(expired.id,support:dir)?.success == false)
        #expect(await co.isPaused == false)
        #expect(try String(contentsOf:target,encoding:.utf8) == "retain")
        #expect(ControlFiles.receipt(id,support:dir) == nil)
    }
    @Test func feedbackCommandIsIdempotent() async throws {
        let store = try DiskTraceStore.inMemory(), t = Date()
        let root = try await store.ensureRoot(canonicalPath:"/r",volumeID:nil,configRevision:1,at:t)
        let c = FileChange(id:UUID(),rootID:root.id,scanID:nil,pathBefore:nil,pathAfter:"/r/a",identityBefore:nil,identityAfter:"a",kind:.added,windowStart:t,windowEnd:t,observedAt:t,beforeLogical:0,afterLogical:1,beforeAllocated:0,afterAllocated:1,deltaAllocated:1,measurement:.measured,timing:.scanWindow,evidenceVersion:1)
        _ = try await store.ensureRoot(canonicalPath:"/r",volumeID:nil,configRevision:1,at:t)
        try await store.insertFileChange(c)
        let assembled = EventAssembler.assemble(changes:[c],windows:[],activities:[:],roots:[root.id:"/r"],configRevision:1,now:t)
        try await store.upsertEvents(assembled,at:t)
        let event = try #require(assembled.first?.event), request = UUID()
        try await store.applyFeedbackCommand(id:request,eventID:event.id,revoke:false,at:t)
        try await store.applyFeedbackCommand(id:request,eventID:event.id,revoke:false,at:t)
        #expect(try await store.activeEventFeedback(eventID:event.id).count == 1)
        #expect(try await store.event(id:event.id)?.attributionClass == .userConfirmed)
        #expect(try await store.controlReceipt(id:request)?.success == true)
    }
    @Test func pagingDoesNotSkipEqualTimestamps() async throws {
        let store = try DiskTraceStore.inMemory(), t = Date()
        let root = try await store.ensureRoot(canonicalPath:"/r",volumeID:nil,configRevision:1,at:t)
        for i in 0..<5 {
            let c = FileChange(id:UUID(),rootID:root.id,scanID:nil,pathBefore:nil,pathAfter:"/r/p\(i)/a",identityBefore:nil,identityAfter:"a\(i)",kind:.added,windowStart:t,windowEnd:t,observedAt:t,beforeLogical:0,afterLogical:1,beforeAllocated:0,afterAllocated:1,deltaAllocated:1,measurement:.measured,timing:.scanWindow,evidenceVersion:1)
            try await store.insertFileChange(c)
            let a = EventAssembler.assemble(changes:[c],windows:[],activities:[:],roots:[root.id:"/r"],configRevision:1,now:t)
            try await store.upsertEvents(a,at:t)
        }
        var found:[UUID] = [], cursor:StorageEvent?
        repeat {
            let page = try await store.queryEvents(rootID:nil,from:t.addingTimeInterval(-1000),to:t.addingTimeInterval(1000),limit:2,before:cursor?.windowEnd,beforeID:cursor?.id)
            if page.isEmpty { break }
            found += page.map(\.id);cursor = page.last
        } while true
        #expect(found.count == 5);#expect(Set(found).count == 5)
    }
}
