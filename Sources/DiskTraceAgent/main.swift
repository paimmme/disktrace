import DiskTraceCore
import Foundation
import Darwin

@main
struct DiskTraceAgentMain {
    static func main() async {
        let options = AgentOptions.parse(CommandLine.arguments)
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Application Support/DiskTrace")
        let database = options.databaseURL ?? support.appending(path: "disktrace.sqlite")

        if options.verifyCodexClient {
            await runCodexAcceptance(databaseURL: database, options: options)
            return
        }

        guard options.interval.isFinite, options.interval > 0,
            options.calibration.isFinite, options.calibration > 0
        else {
            fputs("Invalid sampling/calibration interval\n", stderr)
            exit(2)
        }
        let roots =
            options.roots.isEmpty
            ? AgentOptions.rootsFromSupport(support)
            : options.roots
        let config = MonitorConfig(
            roots: roots.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : roots,
            exclusions: options.exclusions + [support.path],
            sampleInterval: options.interval, calibrationInterval: options.calibration)
        let task = Task {
            try await AgentRuntime.run(
                databaseURL: database, config: config,
                codex: CodexIntegrationConfiguration(
                    codexHome: options.resolvedCodexHome, hashWorkingDirectory: options.hashCodexPaths),
                once: options.once)
        }
        let signals = AgentSignalHandler { task.cancel() }
        do { try await task.value } catch is CancellationError { } catch {
            fputs("disktrace-agent fatal: \(error)\n", stderr)
            exit(1)
        }
        withExtendedLifetime(signals) {}
    }

    static func runCodexAcceptance(databaseURL: URL, options: AgentOptions) async {
        do {
            let lease = try SingleWriterLock(path: databaseURL.path + ".lock")
            defer { lease.release() }
            let store = try DiskTraceStore(path: databaseURL.path)
            await BuildIdentity.record(
                store: store, gitCommit: BuildIdentity.resolveGitCommit(), appVersion: "cli-verify")
            let report = try await CodexClientAcceptance.run(
                codexHome: options.resolvedCodexHome, store: store, writeVerification: true)
            let smoke = try await AttributionSmoke.evaluate(
                store: store, from: Date().addingTimeInterval(-86400), to: Date())
            fputs("=== Codex client acceptance ===\n", stderr)
            for note in report.notes { fputs("  \(note)\n", stderr) }
            fputs("profiles=\(report.profiles.count) windows=\(report.taskWindowsSeen) wrote=\(report.wroteVerification)\n", stderr)
            for p in report.profiles {
                fputs(
                    "  \(p.clientKind.rawValue) \(p.clientVersion) \(p.schemaKind) completed=\(p.completedBoundedWindows) -> \(p.recommended.rawValue)\n",
                    stderr)
            }
            fputs("=== Attribution smoke (24h) ===\n", stderr)
            fputs(
                "  fileChanges=\(smoke.fileChanges) events=\(smoke.eventsWithFiles) pathCandidate=\(smoke.pathCandidateLinks) timeOnly=\(smoke.timeOnlyLinks) unknownEvents=\(smoke.unknownAttributionEvents)\n",
                stderr)
            fputs("  \(smoke.note)\n", stderr)
        } catch {
            fputs("codex acceptance failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

struct AgentOptions {
    var databaseURL: URL?
    var roots: [URL] = []
    var exclusions: [String] = []
    var interval: TimeInterval = 60
    var calibration: TimeInterval = 900
    var once = false
    var codexHome: URL?
    var hashCodexPaths = false
    var verifyCodexClient = false

    var resolvedCodexHome: URL {
        codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
    }

    static func rootsFromSupport(_ support: URL) -> [URL] {
        for name in ["config.json", "local-run.json"] {
            let url = support.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let roots = object["roots"] as? [String]
            else { continue }
            return roots.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
        }
        return []
    }

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
            case "--codex-home":
                if let value = next() { options.codexHome = URL(filePath: value) }
            case "--hash-codex-paths":
                options.hashCodexPaths = true
            case "--calibration":
                if let value = next(), let seconds = TimeInterval(value) { options.calibration = seconds }
            case "--once":
                options.once = true
            case "--verify-codex-client":
                options.verifyCodexClient = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}
