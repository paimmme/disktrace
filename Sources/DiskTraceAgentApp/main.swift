import AppKit
import DiskTraceCore
import Foundation
import UserNotifications

/// The embedded agent app: a menu-bar-less (`LSUIElement`) AppKit process whose
/// only jobs are (a) to own a real notification identity and (b) to run the same
/// `MonitorCoordinator` as the CLI. It never opens a main window and never takes
/// the Dock. Only one writer may run against the database (flock).
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        task = Task.detached(priority: .background) { await AgentAppDelegate.run() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel()
    }

    /// A `UNUserNotificationCenter` sink. Outside a real app bundle the request
    /// would be invalid, so it reports `.failed` instead of pretending success.
    struct SystemNotificationSink: NotificationSink {
        func deliver(item: OutboxItem, title: String, body: String, eventID: UUID?) async -> NotificationSinkResult {
            guard Bundle.main.bundleIdentifier != nil else { return .failed }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                break
            case .denied:
                return .denied
            default:
                return .denied
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let eventID { content.userInfo = ["eventID": eventID.uuidString] }
            let request = UNNotificationRequest(
                identifier: item.id.uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
                return .acceptedByOS
            } catch {
                return .failed
            }
        }
    }

    static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DiskTrace", directoryHint: .isDirectory)
    }

    static func roots(from support: URL) -> [URL] {
        for name in ["config.json", "local-run.json"] {
            let url = support.appending(path: name)
            if let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let roots = object["roots"] as? [String]
            {
                return roots.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            }
        }
        return [FileManager.default.homeDirectoryForCurrentUser]
    }

    static func run() async {
        let support = supportDirectory()
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let dbURL = support.appending(path: "disktrace.sqlite")
        let lock: SingleWriterLock
        do {
            lock = try SingleWriterLock(path: support.appending(path: "agent.lock").path)
        } catch {
            FileHandle.standardError.write(Data("disktrace-agent: another writer is running\n".utf8))
            exit(1)
        }
        defer { lock.release() }

        do {
            let store = try DiskTraceStore(path: dbURL.path)
            let roots = roots(from: support)
            let coordinator = MonitorCoordinator(
                config: MonitorConfig(roots: roots), store: store,
                scanner: FixtureScanner(), scannerName: "fixture",
                activitySync: AgentActivitySync())
            let dispatcher = NotificationDispatcher(
                config: NotificationConfig(), sink: SystemNotificationSink())
            try await coordinator.start()
            while !Task.isCancelled {
                _ = try? await coordinator.runOnce()
                _ = await dispatcher.flush(store: store, now: Date())
                try? await Task.sleep(for: .seconds(15))
            }
            await coordinator.stop()
        } catch {
            FileHandle.standardError.write(Data("disktrace-agent fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}

let delegate = AgentAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
