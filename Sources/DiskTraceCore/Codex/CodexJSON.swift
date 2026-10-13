import Foundation

/// A minimal, structure-aware JSON scanner.
///
/// It exists so the Codex reader can extract a small **whitelist** of keys from
/// a log line without ever deserializing the message, command or tool payloads:
/// it can *skip* any value wholesale (strings, numbers, nested objects/arrays)
/// and only reads the string values of the exact keys it is asked for. It
/// handles escapes, `\uXXXX` (including surrogate pairs) and nesting.
struct CodexJSONScanner {
    private let bytes: [UInt8]
    private var index: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        index = 0
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        index = 0
    }

    struct Malformed: Error {}

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func nextIsObject() -> Bool {
        skipWhitespace()
        return index < bytes.count && bytes[index] == 0x7B
    }

    mutating func nextIsString() -> Bool {
        skipWhitespace()
        return index < bytes.count && bytes[index] == 0x22
    }

    /// Reads a JSON string value at the cursor.
    mutating func readString() throws -> String {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else { throw Malformed() }
        index += 1
        var out: [UInt8] = []
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x22 {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c == 0x5C {  // backslash
                index += 1
                guard index < bytes.count else { throw Malformed() }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75: out.append(contentsOf: try readUnicodeEscape())
                default: out.append(escape)
                }
                continue
            }
            out.append(c)
            index += 1
        }
        throw Malformed()
    }

    private mutating func readUnicodeEscape() throws -> [UInt8] {
        let first = try readHex4()
        var scalarValue = first
        if first >= 0xD800 && first <= 0xDBFF {
            // High surrogate: try to read the paired low surrogate.
            guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                return replacementBytes()
            }
            let save = index
            index += 2
            let second = try readHex4()
            if second >= 0xDC00 && second <= 0xDFFF {
                scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else {
                index = save
                return replacementBytes()
            }
        }
        guard let scalar = Unicode.Scalar(scalarValue) else { return replacementBytes() }
        return Array(String(Character(scalar)).utf8)
    }

    private func replacementBytes() -> [UInt8] { [0xEF, 0xBF, 0xBD] }

    private mutating func readHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw Malformed() }
            let c = bytes[index]
            index += 1
            let digit: UInt32
            switch c {
            case 0x30...0x39: digit = UInt32(c - 0x30)
            case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
            case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
            default: throw Malformed()
            }
            value = (value << 4) | digit
        }
        return value
    }

    /// Skips one complete JSON value of any kind, without interpreting it.
    mutating func skipValue() throws {
        skipWhitespace()
        guard index < bytes.count else { throw Malformed() }
        switch bytes[index] {
        case 0x22:
            _ = try readString()
        case 0x7B:
            try skipObject()
        case 0x5B:
            try skipArray()
        case 0x74, 0x66, 0x6E:  // t/f/n -> true/false/null
            while index < bytes.count, isLiteralByte(bytes[index]) { index += 1 }
        default:
            while index < bytes.count, isNumberByte(bytes[index]) { index += 1 }
        }
    }

    private mutating func skipObject() throws {
        _ = consume(0x7B)
        skipWhitespace()
        if consume(0x7D) { return }
        while index < bytes.count {
            _ = try readString()  // key
            guard consume(0x3A) else { throw Malformed() }
            try skipValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw Malformed() }
        }
        throw Malformed()
    }

    private mutating func skipArray() throws {
        _ = consume(0x5B)
        skipWhitespace()
        if consume(0x5D) { return }
        while index < bytes.count {
            try skipValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw Malformed() }
        }
        throw Malformed()
    }

    private func isLiteralByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    private func isNumberByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
    }
}

/// A parsed log event with only whitelisted fields populated.
struct CodexLogEvent: Sendable, Equatable {
    var type: String?
    var timestamp: Date?
    var sessionID: String?
    var workingDirectory: String?
    var taskID: String?
    var status: String?
}

/// Which event `type` values are recognised, and what that implies. The exact
/// names must be verified per real client (G4); the defaults are the documented
/// shapes and are overridable.
public struct CodexEventSchema: Sendable {
    public var sessionMetadataTypes: Set<String>
    public var taskStartTypes: Set<String>
    public var taskEndTypes: Set<String>

    public init(
        sessionMetadataTypes: Set<String> = [
            "session_meta", "session", "session_started", "session.created",
        ],
        taskStartTypes: Set<String> = [
            "task_started", "task_start", "task_begin", "turn_started", "turn_start",
        ],
        taskEndTypes: Set<String> = [
            "task_completed", "task_complete", "task_end", "task_finished",
            "turn_completed", "turn_complete", "turn_end",
        ]
    ) {
        self.sessionMetadataTypes = sessionMetadataTypes
        self.taskStartTypes = taskStartTypes
        self.taskEndTypes = taskEndTypes
    }

    public static let `default` = CodexEventSchema()

    public func recognizes(_ type: String) -> Bool {
        sessionMetadataTypes.contains(type) || taskStartTypes.contains(type)
            || taskEndTypes.contains(type)
    }

    public func isTaskStart(_ type: String) -> Bool { taskStartTypes.contains(type) }
    public func isTaskEnd(_ type: String) -> Bool { taskEndTypes.contains(type) }
    public func isSessionMetadata(_ type: String) -> Bool { sessionMetadataTypes.contains(type) }
}

enum CodexEventParser {
    /// Top-level keys we are willing to read from any line.
    static let topLevelKeys: Set<String> = [
        "type", "timestamp", "session_id", "id", "cwd", "working_directory",
        "task_id", "turn_id", "status", "event",
    ]
    /// Keys read from a `payload` object, but only for a recognised event type.
    static let payloadKeys: Set<String> = [
        "session_id", "id", "cwd", "working_directory", "task_id", "turn_id", "status", "event",
    ]

    static func parse(_ data: Data, schema: CodexEventSchema) -> CodexLogEvent? {
        var scanner = CodexJSONScanner(data)
        guard scanner.nextIsObject() else { return nil }
        guard let top = try? scanMembers(&scanner, keys: topLevelKeys, descendIntoPayload: false)
        else { return nil }

        var event = CodexLogEvent(
            type: top["type"],
            timestamp: top["timestamp"].flatMap(ISO8601.date(from:)),
            sessionID: top["session_id"] ?? top["id"],
            workingDirectory: top["cwd"] ?? top["working_directory"],
            taskID: top["task_id"] ?? top["turn_id"],
            status: top["status"] ?? top["event"])

        // Only recognised events may have their payload inspected — and only its
        // direct whitelisted keys, never nested bodies.
        if let type = event.type, schema.recognizes(type) {
            var payloadScanner = CodexJSONScanner(data)
            if let payload = try? scanMembers(
                &payloadScanner, keys: payloadKeys, descendIntoPayload: true)
            {
                if event.sessionID == nil { event.sessionID = payload["session_id"] ?? payload["id"] }
                if event.workingDirectory == nil {
                    event.workingDirectory = payload["cwd"] ?? payload["working_directory"]
                }
                if event.taskID == nil { event.taskID = payload["task_id"] ?? payload["turn_id"] }
                if event.status == nil { event.status = payload["status"] ?? payload["event"] }
            }
        }
        return event
    }

    /// Scans one object level. When `descendIntoPayload` is true, the value of a
    /// `payload` key that is itself an object is scanned one level for the same
    /// whitelist; every other non-matching key's value is skipped wholesale.
    private static func scanMembers(
        _ scanner: inout CodexJSONScanner,
        keys: Set<String>,
        descendIntoPayload: Bool
    ) throws -> [String: String] {
        guard scanner.consume(0x7B) else { throw CodexJSONScanner.Malformed() }
        var result: [String: String] = [:]
        if scanner.consume(0x7D) { return result }
        while true {
            let key = try scanner.readString()
            guard scanner.consume(0x3A) else { throw CodexJSONScanner.Malformed() }
            if keys.contains(key) {
                if scanner.nextIsString() {
                    result[key] = try scanner.readString()
                } else {
                    try scanner.skipValue()
                }
            } else if descendIntoPayload, key == "payload", scanner.nextIsObject() {
                if let nested = try? scanMembers(
                    &scanner, keys: CodexSessionLogConstants.payloadKeys, descendIntoPayload: false)
                {
                    for (k, v) in nested where result[k] == nil { result[k] = v }
                }
            } else {
                try scanner.skipValue()
            }
            if scanner.consume(0x7D) { return result }
            guard scanner.consume(0x2C) else { throw CodexJSONScanner.Malformed() }
        }
    }
}

enum CodexSessionLogConstants {
    static let payloadKeys: Set<String> = CodexEventParser.payloadKeys
}

enum ISO8601 {
    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
