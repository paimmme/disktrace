import AppKit
import DiskTraceCore
import Foundation
import UserNotifications

/// The embedded agent app: a menu-bar-less (`LSUIElement`) AppKit process whose
/// only jobs are (a) to own a real notification identity and (b) to run the same
/// `MonitorCoordinator` as the CLI. It never opens a main window and never takes
/// the Dock. Only one writer may run against the database (flock).
final class AgentAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var task: Task<Void, Never>?
    private var signals: AgentSignalHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        task = Task.detached(priority: .background) { await AgentAppDelegate.run() }
        let running = task
        signals = AgentSignalHandler { running?.cancel() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["eventID"] as? String
        let destination = id.flatMap(UUID.init(uuidString:)).map { "disktrace://event/" + $0.uuidString } ?? "disktrace://overview"
        if let url = URL(string: destination) { NSWorkspace.shared.open(url) }
        completionHandler()
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
        return []
    }

    static func configuration(from support: URL) -> MonitorConfig {
        var values: [String: Any] = [:]
        for name in ["config.json", "local-run.json"] {
            if let data = try? Data(contentsOf: support.appending(path: name)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { values = object; break }
        }
        let sample = values["sampleSeconds"] as? Double ?? 60
        let calibration = values["calibrationSeconds"] as? Double ?? 900
        return MonitorConfig(roots: roots(from: support),
            exclusions: (values["exclusions"] as? [String] ?? []) + [support.path],
            sampleInterval: sample.isFinite && sample > 0 ? sample : 60,
            calibrationInterval: calibration.isFinite && calibration > 0 ? calibration : 900,
            inventoryRowBudget: max(1, min(values["inventoryRowBudget"] as? Int ?? 200_000, 1_000_000)),
            inventoryByteBudget: max(1, min(values["inventoryByteBudget"] as? Int64 ?? 192_000_000, 256_000_000)))
    }

    static func run() async {
        let support = supportDirectory()
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let dbURL = support.appending(path: "disktrace.sqlite")
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
        do {
            try await AgentRuntime.run(
                databaseURL: dbURL, config: configuration(from: support),
                codex: CodexIntegrationConfiguration(codexHome: codexHome),
                dispatcher: NotificationDispatcher(config: NotificationConfig(), sink: SystemNotificationSink()),
                nativeCommand: { command in
                    let center = UNUserNotificationCenter.current()
                    if command == .authorizeNotifications {
                        let allowed = try await center.requestAuthorization(options: [.alert])
                        return allowed ? "系统通知已授权" : "系统通知未授权，请在系统设置中开启"
                    }
                    let settings = await center.notificationSettings()
                    guard settings.authorizationStatus == .authorized else { throw CocoaError(.featureUnsupported) }
                    let content = UNMutableNotificationContent()
                    content.title = "DiskTrace 测试提醒"
                    content.body = "后台提醒通道已提交给系统。此消息不代表发现磁盘异常。"
                    try await center.add(UNNotificationRequest(identifier: "disktrace-user-test", content: content, trigger: nil))
                    return "测试提醒已提交给系统"
                })
        } catch is CancellationError { }
        catch {
            FileHandle.standardError.write(Data("disktrace-agent fatal: \(error)\n".utf8))
        }
        await MainActor.run { NSApp.terminate(nil) }

    }
}

let delegate = AgentAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
