import DiskTraceCore
import Foundation
import Darwin

@main
struct DiskTraceAgentMain {
    static func main() async {
        let options = AgentOptions.parse(CommandLine.arguments)
        guard options.interval.isFinite, options.interval > 0,
              options.calibration.isFinite, options.calibration > 0 else {
            fputs("Invalid sampling/calibration interval\n", stderr); exit(2)
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/DiskTrace")
        let database = options.databaseURL ?? support.appending(path: "disktrace.sqlite")
        let roots = options.roots.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : options.roots
        let task = Task {
            try await AgentRuntime.run(databaseURL: database,
                config: MonitorConfig(roots: roots, exclusions: options.exclusions, sampleInterval: options.interval, calibrationInterval: options.calibration),
                codex: CodexIntegrationConfiguration(codexHome: options.codexHome, hashWorkingDirectory: options.hashCodexPaths), once: options.once)
        }
        let signals = AgentSignalHandler { task.cancel() }
        do { try await task.value }
        catch is CancellationError { }
        catch { fputs("disktrace-agent fatal: \(error)\n", stderr); exit(1) }
        withExtendedLifetime(signals) {}
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

    var resolvedCodexHome: URL {
        codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
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
            default:
                break
            }
            index += 1
        }
        return options
    }
}
