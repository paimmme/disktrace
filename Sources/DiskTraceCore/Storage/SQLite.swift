import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public let code: Int32
    public var description: String { "SQLite error \(code): \(message)" }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSince1970) }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    static func optionalInt(_ value: Int64?) -> SQLiteValue { value.map { .int($0) } ?? .null }
    static func optionalDate(_ value: Date?) -> SQLiteValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
}

/// Minimal single-connection SQLite wrapper. DiskTrace uses one writer
/// connection guarded by an actor; the database runs in WAL mode.
final class SQLiteDatabase {
    fileprivate let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open \(path)"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(message: message, code: rc)
        }
        handle = opened
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=5000;")
    }

    static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    deinit { sqlite3_close_v2(handle) }

    /// Rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError(message: message, code: rc)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    /// Runs a statement inside a transaction, rolling back on error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let database: SQLiteDatabase
    private var statement: OpaquePointer?

    init(database: SQLiteDatabase, sql: String) throws {
        self.database = database
        let rc = sqlite3_prepare_v2(database.handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(database.handle)), code: rc)
        }
    }

    deinit { sqlite3_finalize(statement) }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    private func bind(_ value: SQLiteValue, at index: Int32) throws {
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .int(let v):
            rc = sqlite3_bind_int64(statement, index, v)
        case .real(let v):
            rc = sqlite3_bind_double(statement, index, v)
        case .text(let v):
            rc = sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
        }
        guard rc == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(database.handle)), code: rc)
        }
    }

    /// Returns `true` when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteError(message: String(cString: sqlite3_errmsg(database.handle)), code: rc)
        }
    }

    @discardableResult
    func run(_ values: [SQLiteValue] = []) throws -> Bool {
        try bind(values)
        return try step()
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(statement, column)) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }
    func optionalText(_ column: Int32) -> String? {
        isNull(column) ? nil : text(column)
    }
    func optionalDate(_ column: Int32) -> Date? {
        isNull(column) ? nil : date(column)
    }
}
