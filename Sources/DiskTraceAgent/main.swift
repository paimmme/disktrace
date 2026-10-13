import DiskTraceCore
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Process-wide stop flag set from a POSIX signal handler.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

let stopFlag = StopFlag()

@main
struct DiskTraceAgentMain {
    static func main() async {
        let options = AgentOptions.parse(CommandLine.arguments)
        let fileManager = FileManager.default

        let databaseURL = options.databaseURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/DiskTrace", directoryHint: .isDirectory)
                .appending(path: "disktrace.sqlite")
        try? fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let roots = options.roots.isEmpty
            ? [fileManager.homeDirectoryForCurrentUser]
            : options.roots

        do {
            let store = try DiskTraceStore(path: databaseURL.path)
            let config = MonitorConfig(
                roots: roots,
                exclusions: options.exclusions,
                sampleInterval: options.interval)
            let coordinator = MonitorCoordinator(
                config: config,
                store: store,
                scanner: FixtureScanner(),
                scannerName: "fixture")

            signal(SIGTERM) { _ in stopFlag.set() }
            signal(SIGINT) { _ in stopFlag.set() }

            fputs("disktrace-agent starting; db=\(databaseURL.path)\n", stderr)
            for root in roots { fputs("  monitoring root: \(root.path)\n", stderr) }

            try await coordinator.start()
            try await refreshCodexActivities(store: store)

            while true {
                let report = try await coordinator.runOnce()
                let health = await coordinator.health()
                fputs(
                    "cycle: changes=\(report.changeCount) deltas=\(report.deltas.count) "
                        + "decisions=\(report.decisions.count) gaps=\(report.gaps.count) "
                        + "sample=\(report.sample.map { "\($0.freeBytes)B free" } ?? "none") "
                        + "running=\(health.running)\n",
                    stderr)
                if options.once || stopFlag.isSet { break }
                try? await Task.sleep(for: .seconds(options.interval))
            }

            await coordinator.stop()
            fputs("disktrace-agent stopped\n", stderr)
        } catch {
            fputs("disktrace-agent fatal: \(error)\n", stderr)
        }
    }

    private static func refreshCodexActivities(store: DiskTraceStore) async throws {
        let reader = CodexSessionReader()
        let since = Date().addingTimeInterval(-7 * 86_400)
        let activities = (try? await reader.recentActivities(since: since)) ?? []
        for activity in activities {
            try await store.insert(activity)
        }
    }
}

struct AgentOptions {
    var databaseURL: URL?
    var roots: [URL] = []
    var exclusions: [String] = []
    var interval: TimeInterval = 60
    var once = false

    static func parse(_ arguments: [String]) -> AgentOptions {
        var options = AgentOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--db":
                if let value = next() { options.databaseURL = URL(filePath: value) }
            case "--root":
                if let value = next() { options.roots.append(URL(filePath: value)) }
            case "--exclude":
                if let value = next() { options.exclusions.append(value) }
            case "--interval":
                if let value = next(), let seconds = TimeInterval(value) { options.interval = seconds }
            case "--once":
                options.once = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}
