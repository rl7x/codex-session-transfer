import Foundation

public enum HomeKind: String, Codable, Equatable, Sendable {
    case work
    case personal

    public var label: String {
        switch self {
        case .work:
            return "Work (~/.codex-work)"
        case .personal:
            return "Personal (~/.codex)"
        }
    }
}

public struct CodexHomes: Equatable, Sendable {
    public var work: URL
    public var personal: URL

    public init(work: URL, personal: URL) {
        self.work = work
        self.personal = personal
    }

    public static var current: CodexHomes {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CodexHomes(
            work: home.appendingPathComponent(".codex-work", isDirectory: true),
            personal: home.appendingPathComponent(".codex", isDirectory: true)
        )
    }
}

public struct SessionPreview: Equatable, Sendable {
    public var threadID: String
    public var title: String
    public var homeKind: HomeKind
    public var homePath: URL
    public var rolloutPath: String
    public var rolloutBytes: Int64

    public init(
        threadID: String,
        title: String,
        homeKind: HomeKind,
        homePath: URL,
        rolloutPath: String,
        rolloutBytes: Int64
    ) {
        self.threadID = threadID
        self.title = title
        self.homeKind = homeKind
        self.homePath = homePath
        self.rolloutPath = rolloutPath
        self.rolloutBytes = rolloutBytes
    }
}

public struct ImportResult: Equatable, Sendable {
    public var threadID: String
    public var title: String
    public var rolloutPath: String

    public init(threadID: String, title: String, rolloutPath: String) {
        self.threadID = threadID
        self.title = title
        self.rolloutPath = rolloutPath
    }
}

public struct TransferAck: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var threadId: String?

    public init(ok: Bool, message: String, threadId: String? = nil) {
        self.ok = ok
        self.message = message
        self.threadId = threadId
    }
}

enum CodexLayout {
    static let stateDB = "state_5.sqlite"
    static let historyDB = "thread_history_1.sqlite"
    static let historyTables = [
        "thread_turns",
        "thread_items",
        "thread_history_projection_state"
    ]
}

private struct PackageManifest: Codable, Equatable {
    var version: Int
    var threadID: String
    var rolloutRelative: String
    var sourceHomeKind: String
    var title: String
}

private enum PackageFiles {
    static let manifest = "manifest.json"
    static let rollout = "rollout.jsonl"
    static let threads = "state/threads.json"
    static let tools = "state/thread_dynamic_tools.json"

    static func history(_ table: String) -> String {
        "history/\(table).json"
    }
}

private enum PackageJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TransferError.invalidPackage("The session package is unreadable. \(error.localizedDescription)")
        }
    }
}

/// History rows store byte offsets into the rollout, so the jsonl is copied unchanged.
public enum SessionTransfer {
    public static let maxPackageBytes = 1024 * 1024 * 1024
    public static let packageVersion = 1
    private static let titleLimit = 120
    private static let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    public static func lookup(token raw: String, homes: CodexHomes) throws -> SessionPreview {
        let token = normalizeToken(raw)
        if token.isEmpty {
            throw TransferError.emptyToken
        }
        if let found = try find(token: token, home: homes.work, kind: .work) {
            return found
        }
        if let found = try find(token: token, home: homes.personal, kind: .personal) {
            return found
        }
        throw TransferError.sessionNotFound
    }

    public static func package(_ preview: SessionPreview) throws -> Data {
        let home = preview.homePath.standardizedFileURL
        let state = try openReadable(home, file: CodexLayout.stateDB)
        let history = try openReadable(home, file: CodexLayout.historyDB)
        let threads = try snapshot(db: state, table: "threads", column: "id", value: preview.threadID)
        guard threads.rows.count == 1 else {
            throw TransferError.sessionNotFound
        }
        let tools = try snapshot(db: state, table: "thread_dynamic_tools", column: "thread_id", value: preview.threadID)
        var historyTables: [String: TableSnapshot] = [:]
        for table in CodexLayout.historyTables {
            historyTables[table] = try snapshot(db: history, table: table, column: "thread_id", value: preview.threadID)
        }
        let relative = try relativeRollout(preview.rolloutPath, home: home)
        let rolloutURL = URL(fileURLWithPath: preview.rolloutPath).standardizedFileURL
        let rollout = try readRollout(rolloutURL)
        if rollout.count > maxPackageBytes {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let manifest = PackageManifest(
            version: packageVersion,
            threadID: preview.threadID,
            rolloutRelative: relative,
            sourceHomeKind: preview.homeKind.rawValue,
            title: preview.title
        )
        var entries = [
            ZipStore.Entry(name: PackageFiles.manifest, data: try PackageJSON.encode(manifest)),
            ZipStore.Entry(name: PackageFiles.rollout, data: rollout),
            ZipStore.Entry(name: PackageFiles.threads, data: try PackageJSON.encode(threads)),
            ZipStore.Entry(name: PackageFiles.tools, data: try PackageJSON.encode(tools))
        ]
        for table in CodexLayout.historyTables {
            guard let snapshot = historyTables[table] else {
                throw TransferError.schemaMismatch(table)
            }
            entries.append(ZipStore.Entry(name: PackageFiles.history(table), data: try PackageJSON.encode(snapshot)))
        }
        let archive = try ZipStore.archive(entries)
        if archive.count > maxPackageBytes {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        return archive
    }

    public static func importPackage(_ data: Data, into destHome: URL) throws -> ImportResult {
        if data.count > maxPackageBytes {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let files = try ZipStore.extract(data)
        let manifest = try PackageJSON.decode(PackageManifest.self, from: try required(files, PackageFiles.manifest))
        guard manifest.version == packageVersion else {
            throw TransferError.invalidPackage("This Mac cannot read session package version \(manifest.version).")
        }
        try validateRelative(manifest.rolloutRelative)
        let threads = try PackageJSON.decode(TableSnapshot.self, from: try required(files, PackageFiles.threads))
        let tools = try PackageJSON.decode(TableSnapshot.self, from: try required(files, PackageFiles.tools))
        var historyTables: [String: TableSnapshot] = [:]
        for table in CodexLayout.historyTables {
            historyTables[table] = try PackageJSON.decode(
                TableSnapshot.self,
                from: try required(files, PackageFiles.history(table))
            )
        }
        guard let rollout = files[PackageFiles.rollout] else {
            throw TransferError.invalidPackage("The session package is missing the rollout.")
        }
        let thread = try singleThread(threads, expectedID: manifest.threadID)
        try validateChildRows(tools, threadID: manifest.threadID, table: "thread_dynamic_tools")
        for table in CodexLayout.historyTables {
            try validateChildRows(historyTables[table]!, threadID: manifest.threadID, table: table)
        }

        let state = try openWritable(destHome, file: CodexLayout.stateDB)
        let history = try openWritable(destHome, file: CodexLayout.historyDB)
        try requireColumns(state, table: "threads", expected: threads.columns)
        try requireColumns(state, table: "thread_dynamic_tools", expected: tools.columns)
        for table in CodexLayout.historyTables {
            try requireColumns(history, table: table, expected: historyTables[table]!.columns)
        }
        if try threadExists(state, id: manifest.threadID) {
            throw TransferError.alreadyExists(manifest.threadID)
        }

        var values = thread
        if let index = threads.columns.firstIndex(of: "project_id") {
            values[index] = try resolvedParent(state, table: "projects", value: values[index])
        }
        if let index = threads.columns.firstIndex(of: "thread_section_id") {
            values[index] = try resolvedParent(state, table: "thread_sections", value: values[index])
        }
        let destURL = url(home: destHome, relative: manifest.rolloutRelative)
        guard let pathIndex = threads.columns.firstIndex(of: "rollout_path") else {
            throw TransferError.schemaMismatch("threads")
        }
        values[pathIndex] = .text(destURL.path)

        let wroteRollout = try writeRollout(rollout, to: destURL)
        do {
            try state.transaction {
                try insert(state, table: "threads", columns: threads.columns, row: values)
                try replaceRows(state, table: "thread_dynamic_tools", snapshot: tools, threadID: manifest.threadID)
            }
        } catch {
            if wroteRollout {
                try? FileManager.default.removeItem(at: destURL)
            }
            throw error
        }
        do {
            try history.transaction {
                for table in CodexLayout.historyTables {
                    try replaceRows(
                        history,
                        table: table,
                        snapshot: historyTables[table]!,
                        threadID: manifest.threadID
                    )
                }
            }
        } catch {
            try? state.transaction {
                try state.run(
                    "DELETE FROM \"thread_dynamic_tools\" WHERE \"thread_id\" = ?",
                    [.text(manifest.threadID)]
                )
                try state.run("DELETE FROM \"threads\" WHERE \"id\" = ?", [.text(manifest.threadID)])
            }
            if wroteRollout {
                try? FileManager.default.removeItem(at: destURL)
            }
            throw error
        }
        return ImportResult(threadID: manifest.threadID, title: manifest.title, rolloutPath: destURL.path)
    }

    static func normalizeToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeFile = trimmed.contains("/") || trimmed.contains("rollout-") || trimmed.hasSuffix(".jsonl")
        if looksLikeFile, let id = lastUUID(in: trimmed) {
            return id.lowercased()
        }
        if isUUID(trimmed) {
            return trimmed.lowercased()
        }
        return trimmed
    }

    private static func find(token: String, home: URL, kind: HomeKind) throws -> SessionPreview? {
        let stateURL = home.appendingPathComponent(CodexLayout.stateDB)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stateURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        let db = try SQLiteDB(url: stateURL, readonly: true)
        let columns = try db.columnNames("threads")
        guard columns.contains("id"), columns.contains("rollout_path") else {
            throw TransferError.schemaMismatch("threads")
        }
        let selected = columns.map(SQLIdent.quote).joined(separator: ",")
        let base = "SELECT \(selected) FROM \"threads\""
        var rows = try db.query("\(base) WHERE \"id\" = ?", [.text(token)])
        if rows.isEmpty, columns.contains("name") {
            rows = try db.query("\(base) WHERE \"name\" = ?", [.text(token)])
            if rows.count > 1 {
                throw TransferError.ambiguousName(token)
            }
        }
        guard let row = rows.first else { return nil }
        guard let threadID = row["id"]?.text, !threadID.isEmpty else {
            throw TransferError.invalidPackage("The session row has no id.")
        }
        guard let rolloutPath = row["rollout_path"]?.text, !rolloutPath.isEmpty else {
            throw TransferError.rolloutMissing(threadID)
        }
        let rolloutURL = URL(fileURLWithPath: rolloutPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: rolloutURL.path) else {
            throw TransferError.rolloutMissing(rolloutPath)
        }
        let titleSource = row["title"]?.text ?? ""
        let nameSource = row["name"]?.text ?? ""
        return SessionPreview(
            threadID: threadID,
            title: abbreviatedTitle(titleSource.isEmpty ? nameSource : titleSource),
            homeKind: kind,
            homePath: home.standardizedFileURL,
            rolloutPath: rolloutURL.path,
            rolloutBytes: try fileSize(rolloutURL)
        )
    }

    private static func snapshot(db: SQLiteDB, table: String, column: String, value: String) throws -> TableSnapshot {
        let columns = try db.columnNames(table)
        guard columns.contains(column) else {
            throw TransferError.schemaMismatch(table)
        }
        let sql = """
        SELECT \(columns.map(SQLIdent.quote).joined(separator: ","))
        FROM \(SQLIdent.quote(table))
        WHERE \(SQLIdent.quote(column)) = ?
        """
        let dicts = try db.query(sql, [.text(value)])
        let rows = dicts.map { dict in columns.map { dict[$0] ?? .null } }
        return TableSnapshot(columns: columns, rows: rows)
    }

    private static func singleThread(_ snapshot: TableSnapshot, expectedID: String) throws -> [EncodedValue] {
        guard snapshot.rows.count == 1, let row = snapshot.rows.first else {
            throw TransferError.invalidPackage("The session package should contain one thread.")
        }
        guard row.count == snapshot.columns.count else {
            throw TransferError.invalidPackage("The session package has a row that does not match its columns.")
        }
        guard let index = snapshot.columns.firstIndex(of: "id"), case .text(let id) = row[index], id == expectedID else {
            throw TransferError.invalidPackage("The session package thread id does not match.")
        }
        guard snapshot.columns.contains("rollout_path") else {
            throw TransferError.schemaMismatch("threads")
        }
        return row
    }

    private static func validateChildRows(_ snapshot: TableSnapshot, threadID: String, table: String) throws {
        guard let index = snapshot.columns.firstIndex(of: "thread_id") else {
            throw TransferError.schemaMismatch(table)
        }
        for row in snapshot.rows {
            guard row.count == snapshot.columns.count else {
                throw TransferError.invalidPackage("The session package has a row that does not match its columns.")
            }
            guard case .text(let value) = row[index], value == threadID else {
                throw TransferError.invalidPackage("The package mixed in rows from another session.")
            }
        }
    }

    private static func requireColumns(_ db: SQLiteDB, table: String, expected: [String]) throws {
        let actual = try db.columnNames(table)
        if actual != expected {
            throw TransferError.schemaMismatch(table)
        }
    }

    private static func threadExists(_ db: SQLiteDB, id: String) throws -> Bool {
        let rows = try db.query("SELECT 1 FROM \"threads\" WHERE \"id\" = ? LIMIT 1", [.text(id)])
        return !rows.isEmpty
    }

    private static func resolvedParent(_ db: SQLiteDB, table: String, value: EncodedValue) throws -> EncodedValue {
        if case .null = value { return .null }
        let columns = try db.columnNames(table)
        guard columns.contains("id") else {
            throw TransferError.schemaMismatch(table)
        }
        let rows = try db.query(
            "SELECT 1 FROM \(SQLIdent.quote(table)) WHERE \"id\" = ? LIMIT 1",
            [value]
        )
        return rows.isEmpty ? .null : value
    }

    private static func insert(_ db: SQLiteDB, table: String, columns: [String], row: [EncodedValue]) throws {
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
        let sql = """
        INSERT INTO \(SQLIdent.quote(table)) (\(columns.map(SQLIdent.quote).joined(separator: ",")))
        VALUES (\(placeholders))
        """
        try db.run(sql, row)
    }

    private static func replaceRows(_ db: SQLiteDB, table: String, snapshot: TableSnapshot, threadID: String) throws {
        try db.run(
            "DELETE FROM \(SQLIdent.quote(table)) WHERE \"thread_id\" = ?",
            [.text(threadID)]
        )
        for row in snapshot.rows {
            try insert(db, table: table, columns: snapshot.columns, row: row)
        }
    }

    private static func openReadable(_ home: URL, file: String) throws -> SQLiteDB {
        let url = try existingDatabase(home, file: file)
        return try SQLiteDB(url: url, readonly: true)
    }

    private static func openWritable(_ home: URL, file: String) throws -> SQLiteDB {
        let url = try existingDatabase(home, file: file)
        return try SQLiteDB(url: url, readonly: false)
    }

    private static func existingDatabase(_ home: URL, file: String) throws -> URL {
        let url = home.appendingPathComponent(file)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TransferError.databaseMissing(url.path)
        }
        return url
    }

    private static func writeRollout(_ data: Data, to url: URL) throws -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            do {
                let existing = try Data(contentsOf: url)
                if existing != data {
                    throw TransferError.rolloutDiffers(url.path)
                }
                return false
            } catch let error as TransferError {
                throw error
            } catch {
                throw TransferError.rolloutDiffers(url.path)
            }
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    private static func readRollout(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TransferError.rolloutMissing(url.path)
        }
    }

    private static func required(_ files: [String: Data], _ name: String) throws -> Data {
        guard let data = files[name] else {
            throw TransferError.invalidPackage("The session package is missing \(name).")
        }
        return data
    }

    private static func relativeRollout(_ path: String, home: URL) throws -> String {
        let homePath = home.standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard full.hasPrefix(prefix) else {
            throw TransferError.rolloutOutsideHome
        }
        let relative = String(full.dropFirst(prefix.count))
        try validateRelative(relative)
        return relative
    }

    private static func validateRelative(_ relative: String) throws {
        if relative.isEmpty || relative.hasPrefix("/") || relative.contains("\\") || relative.contains("\u{0}") {
            throw TransferError.rolloutOutsideHome
        }
        for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." {
                throw TransferError.rolloutOutsideHome
            }
        }
    }

    private static func url(home: URL, relative: String) -> URL {
        relative.split(separator: "/").reduce(home.standardizedFileURL) { base, part in
            base.appendingPathComponent(String(part))
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw TransferError.rolloutMissing(url.path)
        }
        return Int64(size)
    }

    private static func abbreviatedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Untitled" : trimmed
        if value.count <= titleLimit {
            return value
        }
        return String(value.prefix(titleLimit)) + "…"
    }

    private static func lastUUID(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: uuidPattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func isUUID(_ text: String) -> Bool {
        guard let found = lastUUID(in: text) else { return false }
        return found.caseInsensitiveCompare(text) == .orderedSame
    }
}
