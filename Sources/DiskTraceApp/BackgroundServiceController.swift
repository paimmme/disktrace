import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class BackgroundServiceController: ObservableObject {
    @Published var message: String?
    private var service: SMAppService { .agent(plistName: "local.disktrace.agent.plist") }
    var statusText: String {
        switch service.status {
        case .enabled: return "登录后台已启用"
        case .requiresApproval: return "需要在系统设置中批准后台项目"
        case .notRegistered: return "登录后台未注册"
        case .notFound: return "后台服务尚未被系统识别，请注册后检查系统设置"
        @unknown default: return "后台状态未知"
        }
    }
    func enable() {
        do {
            try service.register()
            if service.status == .enabled {
                // Hand off the local session runner only after login service is approved.
                let process = Process()
                process.executableURL = URL(filePath: "/bin/launchctl")
                process.arguments = ["remove", "local.disktrace.monitor"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
            message = statusText
        }
        catch { message = "注册未完成：\(error.localizedDescription)" }
    }
    func disable() async {
        do { try await service.unregister(); message = "登录后台已取消注册；临时启动的监控不受此操作影响" }
        catch { message = "停止未完成：\(error.localizedDescription)" }
    }
    func openApproval() { SMAppService.openSystemSettingsLoginItems() }
}
