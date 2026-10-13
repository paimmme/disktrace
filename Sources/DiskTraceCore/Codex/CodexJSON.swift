import Foundation

/// Typed, bounded JSON errors. The reader never treats malformed input as a
/// valid event; the caller records a typed gap instead.
public enum CodexJSONError: Error, Equatable, Sendable {
    case expectedString
    case unterminatedString
    case invalidEscape
    case invalidControlCharacter
    case depthExceeded
    case valueTooLarge
    case trailingData
    case malformed
}

/// Counts how many JSON strings the scanner actually materialized. Tests use it
/// to prove that skipped bodies are never decoded (not merely absent from output).
public final class CodexDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    public init() {}
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    public var decodedStrings: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A byte-level, structure-aware JSON scanner.
///
/// It can *skip* any value wholesale — including strings, without ever building
/// a `String` for the skipped bytes — and reads only the exact whitelisted keys
/// the caller asks for. It enforces a nesting depth cap and a metadata value
/// size cap, and rejects malformed input (bad escapes, control characters,
/// truncation) with a typed error rather than looping or guessing.
struct CodexJSONScanner {
    private let bytes: [UInt8]
    private var index: Int
    private let counter: CodexDecodeCounter?
    private let maxValueBytes: Int

    init(_ data: Data, counter: CodexDecodeCounter? = nil, maxValueBytes: Int = 4096) {
        bytes = [UInt8](data)
        index = 0
        self.counter = counter
        self.maxValueBytes = maxValueBytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func consume(_ byte: UInt8) throws -> Bool {
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

    /// Reads a whitelisted string value, decoding escapes. Bounded in size; the
    /// decode counter is incremented because a `String` is materialized.
    mutating func readString() throws -> String {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else { throw CodexJSONError.expectedString }
        index += 1
        var out: [UInt8] = []
        out.reserveCapacity(32)
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x22 {
                index += 1
                counter?.increment()
                return String(decoding: out, as: UTF8.self)
            }
            if c == 0x5C {
                index += 1
                guard index < bytes.count else { throw CodexJSONError.unterminatedString }
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
                default: throw CodexJSONError.invalidEscape
                }
                if out.count > maxValueBytes { throw CodexJSONError.valueTooLarge }
                continue
            }
            if c < 0x20 { throw CodexJSONError.invalidControlCharacter }
            out.append(c)
            if out.count > maxValueBytes { throw CodexJSONError.valueTooLarge }
            index += 1
        }
        throw CodexJSONError.unterminatedString
    }

    /// Skips a JSON string by bytes only. Never allocates a `String` and never
    /// decodes escapes; it validates them so malformed input still fails closed.
    mutating func skipString() throws {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else { throw CodexJSONError.expectedString }
        index += 1
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x22 {
                index += 1
                return
            }
            if c == 0x5C {
                index += 1
                guard index < bytes.count else { throw CodexJSONError.unterminatedString }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    continue
                case 0x75:
                    for _ in 0..<4 {
                        guard index < bytes.count, isHex(bytes[index]) else {
                            throw CodexJSONError.invalidEscape
                        }
                        index += 1
                    }
                default:
                    throw CodexJSONError.invalidEscape
                }
                continue
            }
            if c < 0x20 { throw CodexJSONError.invalidControlCharacter }
            index += 1
        }
        throw CodexJSONError.unterminatedString
    }

    /// Skips one complete JSON value without interpreting it.
    mutating func skipValue(depth: Int = 0) throws {
        guard depth <= 64 else { throw CodexJSONError.depthExceeded }
        skipWhitespace()
        guard index < bytes.count else { throw CodexJSONError.malformed }
        switch bytes[index] {
        case 0x22:
            try skipString()
        case 0x7B:
            try skipObject(depth: depth)
        case 0x5B:
            try skipArray(depth: depth)
        case 0x74, 0x66, 0x6E:
            while index < bytes.count, isLiteralByte(bytes[index]) { index += 1 }
        default:
            guard isNumberByte(bytes[index]) else { throw CodexJSONError.malformed }
            while index < bytes.count, isNumberByte(bytes[index]) { index += 1 }
        }
    }

    private mutating func skipObject(depth: Int) throws {
        guard depth <= 64 else { throw CodexJSONError.depthExceeded }
        guard try consume(0x7B) else { throw CodexJSONError.malformed }
        skipWhitespace()
        if try consume(0x7D) { return }
        while index < bytes.count {
            try skipString()  // key, byte-level
            guard try consume(0x3A) else { throw CodexJSONError.malformed }
            try skipValue(depth: depth + 1)
            skipWhitespace()
            if try consume(0x7D) { return }
            guard try consume(0x2C) else { throw CodexJSONError.malformed }
        }
        throw CodexJSONError.malformed
    }

    private mutating func skipArray(depth: Int) throws {
        guard depth <= 64 else { throw CodexJSONError.depthExceeded }
        guard try consume(0x5B) else { throw CodexJSONError.malformed }
        skipWhitespace()
        if try consume(0x5D) { return }
        while index < bytes.count {
            try skipValue(depth: depth + 1)
            skipWhitespace()
            if try consume(0x5D) { return }
            guard try consume(0x2C) else { throw CodexJSONError.malformed }
        }
        throw CodexJSONError.malformed
    }

    private mutating func readUnicodeEscape() throws -> [UInt8] {
        let first = try readHex4()
        var scalarValue = first
        if first >= 0xD800 && first <= 0xDBFF {
            guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                throw CodexJSONError.invalidEscape
            }
            index += 2
            let second = try readHex4()
            if second >= 0xDC00 && second <= 0xDFFF {
                scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else {
                throw CodexJSONError.invalidEscape
            }
        } else if first >= 0xDC00 && first <= 0xDFFF {
            // Lone low surrogate.
            throw CodexJSONError.invalidEscape
        }
        guard let scalar = Unicode.Scalar(scalarValue) else { throw CodexJSONError.invalidEscape }
        return Array(String(Character(scalar)).utf8)
    }

    private mutating func readHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw CodexJSONError.unterminatedString }
            let c = bytes[index]
            index += 1
            let digit = try hexValue(c)
            value = (value << 4) | digit
        }
        return value
    }

    private func hexValue(_ c: UInt8) throws -> UInt32 {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        default: throw CodexJSONError.invalidEscape
        }
    }

    private func isHex(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x61...0x66, 0x41...0x46: return true
        default: return false
        }
    }

    private func isLiteralByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    private func isNumberByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
    }
}

/// A parsed log event with only whitelisted fields populated. Bodies are never
/// decoded into this type.
struct CodexLogEvent: Sendable, Equatable {
    var topType: String?
    var timestamp: Date?
    var sessionID: String?
    /// True when `session_meta` carried both `id` and `session_id` with different
    /// values — the event must not be linked.
    var sessionIDConflict: Bool = false
    var workingDirectory: String?
    var originator: String?
    var source: String?
    var cliVersion: String?
    /// `event_msg.payload.type` for the envelope form.
    var eventType: String?
    /// `turn_id`/`task_id` when present.
    var taskID: String?
    /// True when a task lifecycle event had no task/turn id.
    var missingTaskID: Bool = false
    /// True when this matched the legacy top-level form rather than the envelope.
    var isLegacy: Bool = false
}

/// Recognised event shapes. Production defaults only enable the observed
/// envelope (`session_meta` / `event_msg`). Legacy top-level lifecycle events
/// are opt-in for old fixtures and never promoted to real-client verification.
public struct CodexEventSchema: Sendable {
    public var sessionMetaTopTypes: Set<String>
    public var eventMsgTopTypes: Set<String>
    public var taskStartedEventTypes: Set<String>
    public var taskCompleteEventTypes: Set<String>
    public var taskAbortedEventTypes: Set<String>
    /// When true, also recognise lifecycle `type` values at the top level.
    public var acceptLegacyTopLevel: Bool
    public var legacyTopLevelStart: Set<String>
    public var legacyTopLevelEnd: Set<String>

    public init(
        sessionMetaTopTypes: Set<String> = ["session_meta"],
        eventMsgTopTypes: Set<String> = ["event_msg"],
        taskStartedEventTypes: Set<String> = ["task_started"],
        taskCompleteEventTypes: Set<String> = ["task_complete", "task_completed"],
        taskAbortedEventTypes: Set<String> = ["turn_aborted", "turn_abort", "task_aborted"],
        acceptLegacyTopLevel: Bool = false,
        legacyTopLevelStart: Set<String> = ["task_started", "task_start", "turn_started"],
        legacyTopLevelEnd: Set<String> = ["task_complete", "task_completed", "turn_completed"]
    ) {
        self.sessionMetaTopTypes = sessionMetaTopTypes
        self.eventMsgTopTypes = eventMsgTopTypes
        self.taskStartedEventTypes = taskStartedEventTypes
        self.taskCompleteEventTypes = taskCompleteEventTypes
        self.taskAbortedEventTypes = taskAbortedEventTypes
        self.acceptLegacyTopLevel = acceptLegacyTopLevel
        self.legacyTopLevelStart = legacyTopLevelStart
        self.legacyTopLevelEnd = legacyTopLevelEnd
    }

    public static let `default` = CodexEventSchema()
    /// Explicitly enables the legacy top-level fixture form.
    public static let legacyFixture = CodexEventSchema(acceptLegacyTopLevel: true)
}

enum CodexEventParser {
    /// Union of payload keys we will ever read (all non-content metadata).
    static let payloadKeyWhitelist: Set<String> = [
        "id", "session_id", "cwd", "originator", "source", "cli_version",
        "type", "turn_id", "task_id",
    ]

    static func parse(
        _ data: Data, schema: CodexEventSchema, counter: CodexDecodeCounter? = nil
    ) -> Result<CodexLogEvent, CodexJSONError> {
        var scanner = CodexJSONScanner(data, counter: counter)
        guard scanner.nextIsObject() else { return .failure(.malformed) }
        var event = CodexLogEvent()
        var payload: [String: String] = [:]
        do {
            guard try scanner.consume(0x7B) else { return .failure(.malformed) }
            if try scanner.consume(0x7D) { return .success(event) }
            while true {
                let key = try scanner.readString()
                guard try scanner.consume(0x3A) else { return .failure(.malformed) }
                switch key {
                case "type":
                    if scanner.nextIsString() {
                        event.topType = try scanner.readString()
                    } else {
                        try scanner.skipValue()
                    }
                case "timestamp":
                    if scanner.nextIsString() {
                        event.timestamp = ISO8601.parse(try scanner.readString())
                    } else {
                        try scanner.skipValue()
                    }
                case "payload":
                    // Only a recognised top-level type may have its payload read;
                    // an unknown event's payload is skipped by bytes, never decoded.
                    if scanner.nextIsObject(), let top = event.topType,
                        shouldReadPayload(top, schema: schema)
                    {
                        payload = try scanPayload(&scanner)
                    } else {
                        try scanner.skipValue()
                    }
                default:
                    try scanner.skipValue()
                }
                if try scanner.consume(0x7D) { break }
                guard try scanner.consume(0x2C) else { return .failure(.malformed) }
            }
            scanner.skipWhitespace()
            if !scanner.isAtEnd { return .failure(.trailingData) }
            finalize(&event, payload: payload, schema: schema)
            return .success(event)
        } catch let error as CodexJSONError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    static func shouldReadPayload(_ topType: String, schema: CodexEventSchema) -> Bool {
        if schema.sessionMetaTopTypes.contains(topType) { return true }
        if schema.eventMsgTopTypes.contains(topType) { return true }
        if schema.acceptLegacyTopLevel,
            schema.legacyTopLevelStart.contains(topType)
                || schema.legacyTopLevelEnd.contains(topType)
        {
            return true
        }
        return false
    }

    static func isTaskLifecycle(_ eventType: String, schema: CodexEventSchema) -> Bool {
        schema.taskStartedEventTypes.contains(eventType)
            || schema.taskCompleteEventTypes.contains(eventType)
            || schema.taskAbortedEventTypes.contains(eventType)
    }

    private static func finalize(
        _ event: inout CodexLogEvent, payload: [String: String], schema: CodexEventSchema
    ) {
        guard let topType = event.topType else { return }
        if schema.sessionMetaTopTypes.contains(topType) {
            let id = payload["id"]
            let sid = payload["session_id"]
            event.sessionID = sid ?? id
            if let id, let sid, id != sid { event.sessionIDConflict = true }
            event.workingDirectory = payload["cwd"]
            event.originator = payload["originator"]
            event.source = payload["source"]
            event.cliVersion = payload["cli_version"]
            return
        }
        if schema.eventMsgTopTypes.contains(topType) {
            event.eventType = payload["type"]
            event.taskID = payload["turn_id"] ?? payload["task_id"]
            if let eventType = event.eventType,
                isTaskLifecycle(eventType, schema: schema), event.taskID == nil
            {
                event.missingTaskID = true
            }
            return
        }
        if schema.acceptLegacyTopLevel,
            schema.legacyTopLevelStart.contains(topType)
                || schema.legacyTopLevelEnd.contains(topType)
        {
            event.isLegacy = true
            event.eventType = topType
            event.taskID = payload["turn_id"] ?? payload["task_id"]
            if event.taskID == nil { event.missingTaskID = true }
        }
    }

    /// Reads the union of whitelisted payload keys; every other key's value is
    /// skipped by bytes (so nested decoys are never decoded).
    private static func scanPayload(_ scanner: inout CodexJSONScanner) throws -> [String: String] {
        guard try scanner.consume(0x7B) else { throw CodexJSONError.malformed }
        var out: [String: String] = [:]
        if try scanner.consume(0x7D) { return out }
        while true {
            let key = try scanner.readString()
            guard try scanner.consume(0x3A) else { throw CodexJSONError.malformed }
            if payloadKeyWhitelist.contains(key), scanner.nextIsString() {
                out[key] = try scanner.readString()
            } else {
                try scanner.skipValue()
            }
            if try scanner.consume(0x7D) { return out }
            guard try scanner.consume(0x2C) else { throw CodexJSONError.malformed }
        }
    }
}

enum ISO8601 {
    /// Parse an ISO-8601 timestamp with or without fractional seconds. Rejects
    /// obviously future times (> now + 5 min) so a bogus clock cannot create a
    /// high-confidence window.
    static func parse(_ string: String, now: Date = Date()) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: string)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: string)
        }
        guard let parsed = date else { return nil }
        if parsed.timeIntervalSince(now) > 300 { return nil }
        return parsed
    }

    static func date(from string: String) -> Date? { parse(string) }
}
