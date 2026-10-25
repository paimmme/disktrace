import Foundation

/// Local acceptance run against real Codex session logs (metadata only).
/// This is the only in-repo path that may write `realClientVerified` to
/// `client_verification`; runtime sync never auto-promotes.
public struct CodexAcceptanceReport: Sendable {
    public struct Profile: Sendable, Hashable {
        public let clientKind: AgentClientKind
        public let clientVersion: String
        public let schemaKind: String
        public let completedBoundedWindows: Int
        public let recommended: VerificationState
    }

    public var syncPasses: Int
    public var activitiesUpserted: Int
    public var taskWindowsSeen: Int
    public var profiles: [Profile]
    public var notes: [String]
    public var wroteVerification: Bool
}

public enum CodexClientAcceptance {
    /// Runs several sync passes with a raised byte budget, then evaluates whether
    /// observed envelopes support `realClientVerified` for each client profile.
    public static func run(
        codexHome: URL,
        store: DiskTraceStore,
        now: Date = Date(),
        writeVerification: Bool = true,
        syncPasses: Int = 6
    ) async throws -> CodexAcceptanceReport {
        var config = CodexIntegrationConfiguration(codexHome: codexHome)
        config.byteBudgetPerSync = 2 * 1024 * 1024
        config.maxFilesPerSync = 200
        let sync = AgentActivitySync(configuration: config)
        var activities = 0
        for _ in 0..<max(1, syncPasses) {
            let result = await sync.sync(store: store, now: now, byteBudget: config.byteBudgetPerSync)
            activities += result.activitiesUpserted
        }

        let windows = try await store.taskWindows(activeSince: now.addingTimeInterval(-86400 * 14))
        var grouped: [String: (AgentClientKind, String, String, Int)] = [:]
        for window in windows {
            let version = window.clientVersion ?? "unknown"
            let key = "\(window.clientKind.rawValue)|\(version)|\(window.schemaKind)"
            var entry = grouped[key] ?? (window.clientKind, version, window.schemaKind, 0)
            if window.startKnown, window.endKnown, window.lifecycle == .completed {
                entry.3 += 1
            }
            grouped[key] = entry
        }

        var profiles: [CodexAcceptanceReport.Profile] = []
        var notes: [String] = []
        for (_, tuple) in grouped.sorted(by: { $0.key < $1.key }) {
            let (kind, version, schema, completed) = tuple
            let recommended: VerificationState
            if schema == "codex-envelope", kind != .unknown, completed >= 1 {
                recommended = .realClientVerified
                notes.append(
                    "Profile \(kind.rawValue) \(version) has \(completed) completed bounded window(s) on schema \(schema).")
            } else if schema == "codex-envelope", completed >= 1 {
                recommended = .unverified
                notes.append("Envelope OK but client kind unknown for version \(version); staying unverified.")
            } else {
                recommended = .unverified
                notes.append("Profile \(kind.rawValue)/\(schema) lacks verified envelope completion.")
            }
            profiles.append(
                CodexAcceptanceReport.Profile(
                    clientKind: kind, clientVersion: version, schemaKind: schema,
                    completedBoundedWindows: completed, recommended: recommended))
        }

        var wrote = false
        if writeVerification {
            for profile in profiles where profile.recommended == .realClientVerified {
                try await store.saveClientVerification(
                    ClientVerification(
                        clientKind: profile.clientKind, clientVersion: profile.clientVersion,
                        schemaKind: profile.schemaKind, result: .realClientVerified,
                        verifiedAt: now,
                        evidenceReference: "codex-acceptance|\(syncPasses)pass|\(profile.completedBoundedWindows)win"))
                wrote = true
            }
        }

        if profiles.isEmpty {
            notes.append("No task windows in the last 14 days after sync; check ~/.codex/sessions and permissions.")
        }

        return CodexAcceptanceReport(
            syncPasses: syncPasses, activitiesUpserted: activities, taskWindowsSeen: windows.count,
            profiles: profiles, notes: notes, wroteVerification: wrote)
    }
}
