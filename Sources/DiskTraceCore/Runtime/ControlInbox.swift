import Darwin
import Foundation

public enum ControlCommand: String, Codable, Sendable {
    case confirmUser, revokeUser, pause, resume, calibrate, authorizeNotifications, notificationTest
    case updateMonitorRoots
}
public struct ControlRequest: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let command: ControlCommand
    public let eventID: UUID?
    public let monitorRoots: [String]?
    public let issuedAt: Date
    public let expiresAt: Date
    public init(
        command: ControlCommand, eventID: UUID? = nil, monitorRoots: [String]? = nil, now: Date = Date()
    ) {
        version = 1
        id = UUID()
        self.command = command
        self.eventID = eventID
        self.monitorRoots = monitorRoots
        issuedAt = now
        expiresAt = now.addingTimeInterval(60)
    }
}
public struct ControlReceipt: Codable, Sendable {
    public let id: UUID
    public let success: Bool
    public let detail: String
}

public enum ControlFiles {
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    static func readOwnedRegular(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0, metadata.st_size <= 16384 else { throw CocoaError(.fileReadNoPermission) }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { buffer in Darwin.read(fd, buffer.baseAddress, buffer.count) }
        guard count == data.count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    public static func submit(_ request: ControlRequest, support: URL) throws {
        let directory = support.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(request.id.uuidString + ".json")
        try encoder().encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func receipt(_ id: UUID, support: URL) -> ControlReceipt? {
        guard let data = try? readOwnedRegular(support.appendingPathComponent("receipts/" + id.uuidString + ".json")) else { return nil }
        return try? decoder().decode(ControlReceipt.self, from: data)
    }
}

public struct ControlInbox: Sendable {
    public let support: URL
    public init(support: URL) { self.support = support }
    public func process(store: DiskTraceStore, coordinator: MonitorCoordinator,
                        native: @Sendable (ControlCommand) async throws -> String) async {
        let fm = FileManager.default
        let directory = support.appendingPathComponent("commands")
        let receipts = support.appendingPathComponent("receipts")
        try? fm.createDirectory(at: receipts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), url.pathExtension == "json" else { continue }
            var statValue = stat()
            guard lstat(url.path, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG,
                  statValue.st_uid == getuid(), statValue.st_mode & 0o077 == 0,
                  statValue.st_size <= 16384 else { continue }
            var receipt: ControlReceipt
            if let old = try? await store.controlReceipt(id: id) { receipt = old }
            else {
                do {
                    let request = try ControlFiles.decoder().decode(ControlRequest.self, from: ControlFiles.readOwnedRegular(url))
                    let now = Date()
                    guard request.id == id, request.version == 1, request.expiresAt >= now,
                          request.issuedAt <= now.addingTimeInterval(5), request.expiresAt.timeIntervalSince(request.issuedAt) <= 300 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var detail = "已应用"
                    switch request.command {
                    case .confirmUser, .revokeUser:
                        guard let eventID = request.eventID else { throw CocoaError(.fileReadCorruptFile) }
                        try await store.applyFeedbackCommand(id: id, eventID: eventID, revoke: request.command == .revokeUser, at: now)
                        detail = (try await store.controlReceipt(id: id))?.detail ?? "已应用"
                    case .pause:
                        try await coordinator.setPaused(true); detail = "扫描已暂停；容量采样继续"
                    case .resume:
                        try await coordinator.setPaused(false); detail = "扫描已恢复，将建立新基线"
                    case .calibrate:
                        await coordinator.requestCalibration(); detail = "校准已排队，完成后刷新查看"
                    case .authorizeNotifications, .notificationTest:
                        detail = try await native(request.command)
                        try await store.setState(request.command == .authorizeNotifications ? "notification_authorization" : "notification_test", detail, at: now)
                    case .updateMonitorRoots:
                        guard let paths = request.monitorRoots, !paths.isEmpty else {
                            throw NSError(domain: "DiskTrace", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "monitorRoots 不能为空",
                            ])
                        }
                        let saved = try LocalRunConfiguration.saveRoots(paths, support: support)
                        try await coordinator.applyMonitorRoots(
                            saved.map { URL(filePath: $0) }, configRevision: coordinator.configRevision + 1)
                        detail = "已更新 \(saved.count) 个监控目录，文件监听已重启"
                    }
                    receipt = ControlReceipt(id: id, success: true, detail: detail)
                } catch { receipt = ControlReceipt(id: id, success: false, detail: "操作未完成：\(error)") }
                try? await store.saveControlReceipt(receipt)
            }
            try? ControlFiles.encoder().encode(receipt).write(to: receipts.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipts.appendingPathComponent(id.uuidString + ".json").path)
            // Only consume validated regular requests owned by this user.
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: receipts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) > 86400 { try? fm.removeItem(at: url) }
        }
    }
}

extension DiskTraceStore {
    public func controlReceipt(id: UUID) throws -> ControlReceipt? {
        let s = try database.prepare("SELECT result,detail_code FROM command_receipts WHERE request_id=?;")
        guard try s.run([.text(id.uuidString)]) else { return nil }
        return ControlReceipt(id: id, success: s.text(0) == "applied", detail: s.optionalText(1) ?? "已应用")
    }
    public func saveControlReceipt(_ receipt: ControlReceipt) throws {
        try rawExecute("INSERT OR IGNORE INTO command_receipts(request_id,command,result,detail_code,processed_at) VALUES (?,'control',?,?,?);",
            [.text(receipt.id.uuidString),.text(receipt.success ? "applied" : "failed"),.text(receipt.detail),.date(Date())])
    }
    public func applyFeedbackCommand(id: UUID, eventID: UUID, revoke: Bool, at date: Date) throws {
        try database.transaction {
            guard try controlReceipt(id: id) == nil else { return }
            guard try count("SELECT COUNT(*) FROM storage_events WHERE id=?;", [.text(eventID.uuidString)]) == 1 else { throw CocoaError(.fileReadNoSuchFile) }
            if revoke { try revokeEventFeedback(eventID: eventID, at: date) }
            else { try addEventFeedback(eventID: eventID, kind: "confirmUser", at: date) }
            try rawExecute("UPDATE notification_outbox SET delivery_state='expired' WHERE event_id=? AND delivery_state IN ('pending','deferredQuietHours');", [.text(eventID.uuidString)])
            try saveControlReceipt(ControlReceipt(id: id, success: true, detail: revoke ? "已撤销确认" : "已确认，这是你的主动操作"))
        }
    }
}
