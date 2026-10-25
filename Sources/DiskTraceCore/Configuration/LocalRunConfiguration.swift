import Foundation

/// Read/write `local-run.json` while preserving unknown keys.
public enum LocalRunConfiguration {
    public static let fileName = "local-run.json"

    public static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DiskTrace", directoryHint: .isDirectory)
    }

    public static func fileURL(support: URL = supportDirectory()) -> URL {
        support.appending(path: fileName)
    }

    public static func load(support: URL = supportDirectory()) throws -> [String: Any] {
        let url = fileURL(support: support)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    public static func roots(support: URL = supportDirectory()) -> [String] {
        (try? load(support: support)["roots"] as? [String]) ?? []
    }

    @discardableResult
    public static func saveRoots(_ roots: [String], support: URL = supportDirectory()) throws -> [String] {
        var object = (try? load(support: support)) ?? [:]
        let canonical = roots.map { FilePaths.canonical(($0 as NSString).expandingTildeInPath) }
        let unique = Array(NSOrderedSet(array: canonical)) as? [String] ?? canonical
        object["roots"] = unique
        let url = fileURL(support: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return unique
    }
}
