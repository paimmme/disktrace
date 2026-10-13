
import Foundation
import Testing
@testable import DiskTraceCore

@Suite("Repair regressions") struct RepairRegressionTests {
    let t = Date(timeIntervalSince1970: 1_700_000_030)
    func change(root:UUID,path:String,delta:Int64) -> FileChange {
        FileChange(id:UUID(),rootID:root,scanID:nil,pathBefore:nil,pathAfter:path,identityBefore:nil,identityAfter:path,kind:.added,windowStart:t.addingTimeInterval(-30),windowEnd:t,observedAt:t,beforeLogical:0,afterLogical:delta,beforeAllocated:0,afterAllocated:delta,deltaAllocated:delta,measurement:.measured,timing:.recoveryWindow,evidenceVersion:1)
    }
    @Test func recoveryWindowMustNotBeProbable() {
        let root=UUID(), id=UUID()
        let a=AgentActivity(id:id,sessionIDHash:"s",client:.codexDesktop,startedAt:t.addingTimeInterval(-20),endedAt:t,workingDirectory:"/r",taskIDHash:"task",windowIsTaskBounded:true)
        let w=TaskWindow(activityID:id,sessionHash:"s",taskHash:"task",clientKind:.codexDesktop,lifecycle:.completed,startKnown:true,endKnown:true,lastEventAt:t,schemaKind:"codex-envelope",verification:.realClientVerified,sourceLogPath:"/log")
        let result=EventAssembler.assemble(changes:[change(root:root,path:"/r/new",delta:200_000_000)],windows:[w],activities:[id:a],roots:[root:"/r"],configRevision:1,now:t)
        #expect(result[0].event.attributionClass == .unknown)
    }
    @Test func repeatedEventMustRetainFilesAndFeedback() async throws {
        let store=try DiskTraceStore.inMemory()
        let root=try await store.ensureRoot(canonicalPath:"/r",volumeID:"v",configRevision:1,at:t)
        let c1=change(root:root.id,path:"/r/a",delta:10),c2=change(root:root.id,path:"/r/b",delta:20)
        try await store.insertFileChange(c1);try await store.insertFileChange(c2)
        let first=EventAssembler.assemble(changes:[c1],windows:[],activities:[:],roots:[root.id:"/r"],configRevision:1,now:t)
        let second=EventAssembler.assemble(changes:[c2],windows:[],activities:[:],roots:[root.id:"/r"],configRevision:1,now:t)
        #expect(first[0].event.id == second[0].event.id)
        try await store.upsertEvents(first,at:t)
        try await store.addEventFeedback(eventID:first[0].event.id,kind:"confirmUser",at:t)
        try await store.upsertEvents(second,at:t)
        let files=try await store.queryFileChanges(eventID:first[0].event.id)
        let feedback=try await store.activeEventFeedback(eventID:first[0].event.id)
        let events=try await store.queryEvents(rootID:nil,from:t.addingTimeInterval(-1000),to:t.addingTimeInterval(1000))
        print("AUDIT overwritten event: files=\(files.count), feedback=\(feedback.count), net=\(events[0].netBytes ?? -1)")
        #expect(files.count == 2)
        #expect(feedback.count == 1)
        #expect(events[0].netBytes == 30)
    }
    @Test func directoryPathMustNotBypassVerification() async throws {
        let r=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:r,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:r) }
        let store=try DiskTraceStore.inMemory()
        var policy=AlertPolicyConfig();policy.agentGrowthThresholdBytes=1000;policy.lowSpaceFreeBytes=0;policy.lowSpaceFreeFraction=0
        let co=MonitorCoordinator(config:.init(roots:[r],sampleInterval:100000,calibrationInterval:0,policy:policy),store:store)
        try await co.start()
        let now=Date(),path=FilePaths.canonical(r.path)
        let a=AgentActivity(sessionIDHash:"unverified",client:.unknown,startedAt:now.addingTimeInterval(-1),endedAt:now.addingTimeInterval(30),workingDirectory:path,windowIsTaskBounded:true)
        try await store.insert(a)
        try await store.upsertTaskWindow(TaskWindow(activityID:a.id,sessionHash:"unverified",taskHash:"task",clientKind:.unknown,lifecycle:.completed,startKnown:true,endKnown:true,lastEventAt:now,schemaKind:"unknown",verification:.unverified,sourceLogPath:"/log"))
        try Data(repeating:65,count:100000).write(to:r.appendingPathComponent("new.bin"))
        let report=try await co.runOnce()
        print("AUDIT directory decisions: \(report.decisions.map { $0.reason.rawValue })")
        #expect(!report.decisions.contains { $0.action == .notifyAgentAnomaly })
        await co.stop()
    }
}
