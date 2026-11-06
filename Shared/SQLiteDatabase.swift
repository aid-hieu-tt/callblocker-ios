import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: LocalizedError, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
    var errorDescription: String? { description }
}

enum SQLValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

/// Wrapper tối giản quanh SQLite C API — không phụ thuộc thư viện ngoài để giữ
/// footprint của Extension nhỏ nhất có thể.
final class SQLiteDatabase {
    fileprivate let handle: OpaquePointer

    init(path: String, busyTimeoutMs: Int32 = 10_000) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, busyTimeoutMs)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw SQLiteError(code: rc, message: "\(lastErrorMessage) — \(sql)")
        }
        return Statement(database: self, handle: prepared)
    }

    /// `BEGIN IMMEDIATE` giữ write-lock ngay từ đầu, tránh deadlock khi App và Extension cùng ghi.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalarInt64(_ sql: String, _ values: SQLValue...) throws -> Int64? {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        guard try stmt.step(), !stmt.isNull(at: 0) else { return nil }
        return stmt.int64(at: 0)
    }

    func scalarString(_ sql: String, _ values: SQLValue...) throws -> String? {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        guard try stmt.step(), !stmt.isNull(at: 0) else { return nil }
        return stmt.string(at: 0)
    }
}

final class Statement {
    private let database: SQLiteDatabase // giữ connection sống lâu hơn statement
    private let handle: OpaquePointer
    private(set) var iterationError: Error?
    /// `true` sau khi `sqlite3_step` trả `SQLITE_DONE`. Gọi step tiếp mà không reset sẽ khiến SQLite
    /// báo lỗi hoặc tự chạy lại truy vấn từ đầu — iterator phải "đứng yên" khi đã hết dữ liệu.
    private var exhausted = false

    fileprivate init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        iterationError = nil
        exhausted = false
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(handle, index, v)
            case .real(let v): rc = sqlite3_bind_double(handle, index, v)
            case .text(let v): rc = sqlite3_bind_text(handle, index, v, -1, SQLITE_TRANSIENT)
            case .null: rc = sqlite3_bind_null(handle, index)
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: database.lastErrorMessage) }
        }
    }

    /// `true` nếu có dòng dữ liệu, `false` khi hết.
    func step() throws -> Bool {
        guard !exhausted else { return false }
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE:
            exhausted = true
            return false
        default:
            exhausted = true
            throw SQLiteError(code: rc, message: database.lastErrorMessage)
        }
    }

    /// Phiên bản không-throw dùng trong `IteratorProtocol`; lỗi được giữ lại để kiểm tra sau.
    func nextRow() -> Bool {
        guard iterationError == nil, !exhausted else { return false }
        do {
            return try step()
        } catch {
            iterationError = error
            return false
        }
    }

    func throwIfIterationFailed() throws {
        if let error = iterationError { throw error }
    }

    func run(_ values: SQLValue...) throws {
        try bind(values)
        while try step() {}
    }

    func int64(at column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(at column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(at column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func string(at column: Int32) -> String {
        guard let text = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: text)
    }
}
