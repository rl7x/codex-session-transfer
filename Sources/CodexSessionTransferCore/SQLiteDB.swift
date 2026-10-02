import Foundation
import SQLite3

enum SQLIdent {
    static func quote(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum EncodedValue: Codable, Equatable, Sendable {
    case null
    case int(String)
    case real(Double)
    case text(String)
    case blob(String)

    private enum CodingKeys: String, CodingKey {
        case null
        case int
        case real
        case text
        case blob
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.null) {
            self = .null
            return
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .int) {
            self = .int(value)
            return
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .real) {
            self = .real(value)
            return
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(value)
            return
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .blob) {
            self = .blob(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing SQLite value")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(true, forKey: .null)
        case .int(let value):
            try container.encode(value, forKey: .int)
        case .real(let value):
            try container.encode(value, forKey: .real)
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .blob(let value):
            try container.encode(value, forKey: .blob)
        }
    }
}

struct TableSnapshot: Codable, Equatable, Sendable {
    var columns: [String]
    var rows: [[EncodedValue]]
}

final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let allowedTables: Set<String> = [
        "threads",
        "thread_dynamic_tools",
        "thread_turns",
        "thread_items",
        "thread_history_projection_state",
        "projects",
        "thread_sections"
    ]

    init(url: URL, readonly: Bool) throws {
        var opened: OpaquePointer?
        let flags: Int32 = readonly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(url.path, &opened, flags, nil)
        handle = opened
        if rc != SQLITE_OK {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close_v2(opened)
            handle = nil
            throw TransferError.sqlite(message)
        }
        try run("PRAGMA busy_timeout=30000")
        if !readonly {
            try run("PRAGMA foreign_keys=ON")
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func columnNames(_ table: String) throws -> [String] {
        guard Self.allowedTables.contains(table) else {
            throw TransferError.schemaMismatch(table)
        }
        let rows = try query("PRAGMA table_info(\(table))")
        if rows.isEmpty {
            throw TransferError.schemaMismatch(table)
        }
        return try rows.map { row in
            guard let name = row["name"]?.text else {
                throw TransferError.schemaMismatch(table)
            }
            return name
        }
    }

    func query(_ sql: String, _ params: [EncodedValue] = []) throws -> [[String: EncodedValue]] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let count = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(count)
        for index in 0..<count {
            guard let name = sqlite3_column_name(statement, Int32(index)) else {
                throw lastError()
            }
            names.append(String(cString: name))
        }
        var rows: [[String: EncodedValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw lastError(rc: rc) }
            var row: [String: EncodedValue] = [:]
            for index in 0..<count {
                row[names[index]] = columnValue(statement, Int32(index))
            }
            rows.append(row)
        }
        return rows
    }

    func run(_ sql: String, _ params: [EncodedValue] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw lastError(rc: rc)
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [EncodedValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        if rc != SQLITE_OK {
            sqlite3_finalize(statement)
            throw lastError(rc: rc)
        }
        for (offset, value) in params.enumerated() {
            try bind(value, at: Int32(offset + 1), statement: statement)
        }
        return statement
    }

    private func bind(_ value: EncodedValue, at index: Int32, statement: OpaquePointer?) throws {
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .int(let raw):
            guard let number = Int64(raw) else {
                throw TransferError.invalidPackage("The session package contains an invalid integer.")
            }
            rc = sqlite3_bind_int64(statement, index, number)
        case .real(let number):
            rc = sqlite3_bind_double(statement, index, number)
        case .text(let text):
            try bindText(text, statement: statement, index: index)
            return
        case .blob(let encoded):
            guard let data = Data(base64Encoded: encoded) else {
                throw TransferError.invalidPackage("The session package contains an invalid blob.")
            }
            try bindBlob(data, statement: statement, index: index)
            return
        }
        if rc != SQLITE_OK {
            throw lastError(rc: rc)
        }
    }

    private func bindText(_ text: String, statement: OpaquePointer?, index: Int32) throws {
        let bytes = Array(text.utf8)
        guard bytes.count <= Int(Int32.max) else {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let rc: Int32
        if bytes.isEmpty {
            rc = sqlite3_bind_text(statement, index, "", 0, Self.transient)
        } else {
            rc = bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return sqlite3_bind_text(statement, index, "", 0, Self.transient)
                }
                return base.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                    sqlite3_bind_text(statement, index, pointer, Int32(bytes.count), Self.transient)
                }
            }
        }
        if rc != SQLITE_OK {
            throw lastError(rc: rc)
        }
    }

    private func bindBlob(_ data: Data, statement: OpaquePointer?, index: Int32) throws {
        guard data.count <= Int(Int32.max) else {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let rc: Int32
        if data.isEmpty {
            var dummy: UInt8 = 0
            rc = sqlite3_bind_blob(statement, index, &dummy, 0, Self.transient)
        } else {
            rc = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), Self.transient)
            }
        }
        if rc != SQLITE_OK {
            throw lastError(rc: rc)
        }
    }

    private func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> EncodedValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .int(String(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
                return .blob(Data().base64EncodedString())
            }
            return .blob(Data(bytes: pointer, count: count).base64EncodedString())
        default:
            if let text = sqlite3_column_text(statement, index) {
                return .text(String(cString: text))
            }
            return .text("")
        }
    }

    private func lastError(rc: Int32? = nil) -> TransferError {
        let code = rc ?? sqlite3_errcode(handle)
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return .sqlite("Codex is using its database. Try again in a moment.")
        }
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
        return .sqlite(message)
    }
}
