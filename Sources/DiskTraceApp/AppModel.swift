import DiskTraceCore
import Foundation

/// Read-only view model for the UI. The App is never a writer: it opens the
/// agent's SQLite store read-only and renders snapshots (ADR-03).
@MainActor
final class AppModel: ObservableObject {
    @Published var samples: [VolumeSample] = []
    @Published var growth: [DirectoryDelta] = []
    @Published var alerts: [AlertDecision] = []
    @Published var status = "Loading…"
    @Published var databasePath: String

    init(databasePath: String? = nil) {
        self.databasePath = databasePath ?? Self.defaultDatabasePath()
    }

    static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DiskTrace/disktrace.sqlite").path
    }

    func refresh() async {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            status = "No agent database at \(databasePath). Start disktrace-agent first."
            return
        }
        do {
            let store = try DiskTraceStore(path: databasePath)
            let now = Date()
            let from = now.addingTimeInterval(-7 * 86_400)
            samples = try await store.timelineSamples(from: from, to: now)
            growth = try await store.directoryDeltas(
                from: from, to: now, minimumGrowth: 1_000_000)
            alerts = try await store.notifyingDecisions(from: from, to: now)
            status =
                "Loaded \(samples.count) samples, \(growth.count) growth rows, "
                + "\(alerts.count) alerts."
        } catch {
            status = "Failed to read database: \(error)"
        }
    }
}
