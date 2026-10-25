import Darwin
import Dispatch
import Foundation

/// Both the CLI and embedded Agent use this lease and scheduling implementation.
public enum AgentRuntime {
    public static func run(databaseURL: URL, config: MonitorConfig,
                           codex: CodexIntegrationConfiguration = .init(), once: Bool = false,
                           dispatcher: NotificationDispatcher? = nil,
                           nativeCommand: @escaping @Sendable (ControlCommand) async throws -> String = { _ in throw CocoaError(.featureUnsupported) }) async throws {
        let support = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lease = try SingleWriterLock(path: databaseURL.path + ".lock")
        defer { lease.release() }
        let store = try DiskTraceStore(path: databaseURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        await BuildIdentity.record(
            store: store, gitCommit: BuildIdentity.resolveGitCommit(), appVersion: nil)
        let coordinator = MonitorCoordinator(config: config, store: store, activitySync: AgentActivitySync(configuration: codex))
        if once {
            try await coordinator.start()
            _ = try await coordinator.runOnce()
            await coordinator.stop()
            return
        }
        let inbox = ControlInbox(support: support)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        do { try await coordinator.sampleIfDue() }
                        catch { try? await store.setState("sample_error", String(describing: error), at: Date()) }
                        try await store.setState("heartbeat_at", String(Date().timeIntervalSince1970), at: Date())
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                group.addTask {
                    try await coordinator.start()
                    while !Task.isCancelled {
                        do { _ = try await coordinator.runOnce(sampleCapacity: false) }
                        catch is CancellationError { if Task.isCancelled { throw CancellationError() } }
                        catch { try? await store.setState("work_error", String(describing: error), at: Date()) }
                        try await Task.sleep(for: .seconds(5))
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        await inbox.process(store: store, coordinator: coordinator, native: nativeCommand)
                        if let dispatcher { _ = await dispatcher.flush(store: store, now: Date()) }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                defer { group.cancelAll() }
                try await group.waitForAll()
            }
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }
}

/// Dispatch handles signals outside the async-signal-unsafe C callback context.
public final class AgentSignalHandler {
    private var sources: [DispatchSourceSignal] = []
    public init(cancel: @escaping @Sendable () -> Void) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: cancel)
            source.resume()
            sources.append(source)
        }
    }
    deinit { for source in sources { source.cancel() } }
}
