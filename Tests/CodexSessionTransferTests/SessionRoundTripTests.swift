import XCTest
@testable import CodexSessionTransferCore

final class SessionRoundTripTests: XCTestCase {
    private let threadID = "01a0fdc0-4569-7da2-8a19-6c468980b706"
    private let rolloutBody = Data("{\"type\":\"session_meta\"}\n".utf8)
    private let bigOffset = "9007199254740993"
    private let blob = Data([1, 2, 3, 255])
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }

    func testPackageAndImportRoundTrip() throws {
        let root = try tempRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let title = String(repeating: "a", count: 121)
        try seed(source, title: title)
        try makeDestination(destination)

        let homes = CodexHomes(work: root.appendingPathComponent("missing-work"), personal: source)
        let preview = try SessionTransfer.lookup(token: threadID.uppercased(), homes: homes)
        XCTAssertEqual(preview.homeKind, .personal)
        XCTAssertEqual(preview.threadID, threadID)
        XCTAssertEqual(preview.title.count, 121)
        XCTAssertTrue(preview.title.hasSuffix("…"))

        let archive = try SessionTransfer.package(preview)
        let files = try ZipStore.extract(archive)
        XCTAssertEqual(
            Set(files.keys),
            [
                "manifest.json",
                "rollout.jsonl",
                "state/threads.json",
                "state/thread_dynamic_tools.json",
                "history/thread_turns.json",
                "history/thread_items.json",
                "history/thread_history_projection_state.json"
            ]
        )
        let turns = try String(data: XCTUnwrap(files["history/thread_turns.json"]), encoding: .utf8)
        XCTAssertTrue(turns?.contains("\"\(bigOffset)\"") == true)

        let result = try SessionTransfer.importPackage(archive, into: destination)
        XCTAssertEqual(result.threadID, threadID)
        XCTAssertTrue(result.rolloutPath.hasPrefix(destination.path + "/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.rolloutPath)), rolloutBody)

        let state = try SQLiteDB(url: destination.appendingPathComponent("state_5.sqlite"), readonly: true)
        let threads = try state.query("SELECT * FROM threads")
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0]["project_id"], .text("p1"))
        XCTAssertEqual(threads[0]["thread_section_id"], .null)
        XCTAssertEqual(threads[0]["created_at"], .int("1790963631"))
        XCTAssertEqual(threads[0]["rollout_path"]?.text, result.rolloutPath)
        let tools = try state.query("SELECT payload FROM thread_dynamic_tools WHERE thread_id = ?", [.text(threadID)])
        XCTAssertEqual(tools.first?["payload"], .blob(blob.base64EncodedString()))

        let history = try SQLiteDB(url: destination.appendingPathComponent("thread_history_1.sqlite"), readonly: true)
        let turnRows = try history.query("SELECT note, rollout_byte_offset FROM thread_turns")
        XCTAssertEqual(turnRows.first?["note"], .null)
        XCTAssertEqual(turnRows.first?["rollout_byte_offset"], .int(bigOffset))
        let items = try history.query("SELECT item_json FROM thread_items")
        XCTAssertEqual(items.first?["item_json"], .text("{\"type\":\"message\"}"))

        XCTAssertThrowsError(try SessionTransfer.importPackage(archive, into: destination)) { error in
            XCTAssertEqual(error as? TransferError, .alreadyExists(threadID))
        }
        let after = try history.query("SELECT COUNT(*) AS count FROM thread_turns")
        XCTAssertEqual(after.first?["count"], .int("1"))
    }

    func testWorkHomeWinsAndPersonalIsFallback() throws {
        let root = try tempRoot()
        let work = root.appendingPathComponent("work", isDirectory: true)
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try seed(work, title: "From work")
        try seed(personal, title: "From personal")
        let both = CodexHomes(work: work, personal: personal)
        let preferred = try SessionTransfer.lookup(token: threadID, homes: both)
        XCTAssertEqual(preferred.homeKind, .work)
        XCTAssertEqual(preferred.title, "From work")

        let emptyWork = root.appendingPathComponent("empty-work", isDirectory: true)
        try seed(emptyWork, title: "Unused", includeThread: false)
        let fallback = try SessionTransfer.lookup(
            token: "rollout-2026-10-02T13-53-51-\(threadID).jsonl",
            homes: CodexHomes(work: emptyWork, personal: personal)
        )
        XCTAssertEqual(fallback.homeKind, .personal)
        XCTAssertEqual(fallback.threadID, threadID)

        let byName = try SessionTransfer.lookup(token: "Website", homes: CodexHomes(work: emptyWork, personal: personal))
        XCTAssertEqual(byName.threadID, threadID)
    }

    func testAmbiguousNameAndMissingSession() throws {
        let root = try tempRoot()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try seed(home, title: "Named")
        let state = try SQLiteDB(url: home.appendingPathComponent("state_5.sqlite"), readonly: false)
        try state.run(
            """
            INSERT INTO threads (id, rollout_path, title, name, project_id, thread_section_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text("01a0fdc0-4569-7da2-8a19-6c468980b707"),
                .text("/tmp/other.jsonl"),
                .text("Other"),
                .text("Website"),
                .null,
                .null,
                .int("2")
            ]
        )
        let homes = CodexHomes(work: home, personal: root.appendingPathComponent("absent"))
        XCTAssertThrowsError(try SessionTransfer.lookup(token: "Website", homes: homes)) { error in
            XCTAssertEqual(error as? TransferError, .ambiguousName("Website"))
        }
        XCTAssertThrowsError(try SessionTransfer.lookup(token: "   ", homes: homes)) { error in
            XCTAssertEqual(error as? TransferError, .emptyToken)
        }
        XCTAssertThrowsError(try SessionTransfer.lookup(token: "missing-session", homes: homes)) { error in
            XCTAssertEqual(error as? TransferError, .sessionNotFound)
        }
    }

    func testRolloutOutsideHomeIsNotPackaged() throws {
        let root = try tempRoot()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let outside = root.appendingPathComponent("outside.jsonl")
        try rolloutBody.write(to: outside)
        try seed(home, title: "Outside", rolloutPath: outside.path)
        let preview = try SessionTransfer.lookup(
            token: threadID,
            homes: CodexHomes(work: root.appendingPathComponent("missing"), personal: home)
        )
        XCTAssertThrowsError(try SessionTransfer.package(preview)) { error in
            XCTAssertEqual(error as? TransferError, .rolloutOutsideHome)
        }
    }

    func testSchemaMismatchRolloutConflictAndIdenticalFile() throws {
        let root = try tempRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try seed(source, title: "Schema")
        let preview = try SessionTransfer.lookup(
            token: threadID,
            homes: CodexHomes(work: root.appendingPathComponent("missing"), personal: source)
        )
        let archive = try SessionTransfer.package(preview)

        let mismatched = root.appendingPathComponent("mismatched", isDirectory: true)
        try makeDestination(mismatched, extraColumn: true)
        XCTAssertThrowsError(try SessionTransfer.importPackage(archive, into: mismatched)) { error in
            XCTAssertEqual(error as? TransferError, .schemaMismatch("threads"))
        }

        let different = root.appendingPathComponent("different", isDirectory: true)
        try makeDestination(different)
        let differentFile = different.appendingPathComponent(relativePath())
        try FileManager.default.createDirectory(at: differentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: differentFile)
        XCTAssertThrowsError(try SessionTransfer.importPackage(archive, into: different)) { error in
            XCTAssertEqual(error as? TransferError, .rolloutDiffers(differentFile.path))
        }
        let differentState = try SQLiteDB(url: different.appendingPathComponent("state_5.sqlite"), readonly: true)
        XCTAssertTrue(try differentState.query("SELECT id FROM threads").isEmpty)

        let sameFile = root.appendingPathComponent("same-file", isDirectory: true)
        try makeDestination(sameFile)
        let existing = sameFile.appendingPathComponent(relativePath())
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rolloutBody.write(to: existing)
        let imported = try SessionTransfer.importPackage(archive, into: sameFile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported.rolloutPath)), rolloutBody)

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SessionTransfer.importPackage(archive, into: empty)) { error in
            guard case TransferError.databaseMissing = error else {
                return XCTFail("Expected a missing database, got \(error)")
            }
        }
    }

    func testPackageIgnoresExtraFilesAndRejectsEscapingPaths() throws {
        let root = try tempRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try seed(source, title: "Safe")
        try makeDestination(destination)
        let preview = try SessionTransfer.lookup(
            token: threadID,
            homes: CodexHomes(work: root.appendingPathComponent("missing"), personal: source)
        )
        let archive = try SessionTransfer.package(preview)
        var files = try ZipStore.extract(archive)
        files["auth.json"] = Data("secret".utf8)
        let withSecret = try ZipStore.archive(files.map { ZipStore.Entry(name: $0.key, data: $0.value) })
        _ = try SessionTransfer.importPackage(withSecret, into: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path))

        let escapedDest = root.appendingPathComponent("escaped", isDirectory: true)
        try makeDestination(escapedDest)
        var escapedFiles = try ZipStore.extract(archive)
        let manifest = try XCTUnwrap(String(data: XCTUnwrap(escapedFiles["manifest.json"]), encoding: .utf8))
        XCTAssertTrue(manifest.contains(relativePath()))
        escapedFiles["manifest.json"] = Data(manifest.replacingOccurrences(of: relativePath(), with: "../auth.json").utf8)
        let escaped = try ZipStore.archive(escapedFiles.map { ZipStore.Entry(name: $0.key, data: $0.value) })
        XCTAssertThrowsError(try SessionTransfer.importPackage(escaped, into: escapedDest)) { error in
            XCTAssertEqual(error as? TransferError, .rolloutOutsideHome)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path))
        let escapedState = try SQLiteDB(url: escapedDest.appendingPathComponent("state_5.sqlite"), readonly: true)
        XCTAssertTrue(try escapedState.query("SELECT id FROM threads").isEmpty)
    }
}

final class MacDiscoveryTests: XCTestCase {
    func testDropsThisMacAndPhonesAndSelectsTheReceiver() {
        let macs = MacDiscovery.merge(
            localNames: MacDiscovery.localNames(serviceName: "mbp", hostName: "mbp.local"),
            receivers: ["mbp", "MacBook Pro"],
            nearby: ["mbp", "MacBook Pro", "iMac", "Sam's iPad"]
        )
        XCTAssertEqual(macs.map(\.name), ["MacBook Pro", "iMac"])
        XCTAssertEqual(macs.map(\.receiving), [true, false])
        XCTAssertEqual(MacDiscovery.automaticSelection(in: macs)?.name, "MacBook Pro")
    }

    func testTwoReceiversStayUnselected() {
        let macs = MacDiscovery.merge(
            localNames: ["mbp"],
            receivers: ["MacBook Pro", "iMac"],
            nearby: ["MacBook Pro", "iMac"]
        )
        XCTAssertNil(MacDiscovery.automaticSelection(in: macs))
    }

    func testOnlyOtherMacIsSelectedWhenNothingIsReceiving() {
        let macs = MacDiscovery.merge(
            localNames: ["mbp"],
            receivers: [],
            nearby: ["iMac", "mbp", "iPhone"]
        )
        XCTAssertEqual(macs.map(\.name), ["iMac"])
        XCTAssertEqual(MacDiscovery.automaticSelection(in: macs)?.receiving, false)
    }
}

final class ZipAndProtocolTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.hash(Data("123456789".utf8)), 0xCBF43926)
    }

    func testZipRoundTripAndRejectedNames() throws {
        let entries = [
            ZipStore.Entry(name: "history/thread_items.json", data: Data("[]".utf8)),
            ZipStore.Entry(name: "notes/タイトル.txt", data: Data("ok".utf8))
        ]
        let archive = try ZipStore.archive(entries)
        let files = try ZipStore.extract(archive)
        XCTAssertEqual(files["history/thread_items.json"], Data("[]".utf8))
        XCTAssertEqual(files["notes/タイトル.txt"], Data("ok".utf8))

        XCTAssertThrowsError(try ZipStore.archive([ZipStore.Entry(name: "../x", data: Data())]))
        let unsafe = try ZipStore.archive(
            [ZipStore.Entry(name: "../auth.json", data: Data("secret".utf8))],
            validateNames: false
        )
        XCTAssertThrowsError(try ZipStore.extract(unsafe))
    }

    func testHostPortParsing() {
        XCTAssertEqual(HostPort.parse("mac2.local:47655")?.host, "mac2.local")
        XCTAssertEqual(HostPort.parse("mac2.local:47655")?.port, 47655)
        XCTAssertEqual(HostPort.parse("127.0.0.1:80")?.port, 80)
        XCTAssertEqual(HostPort.parse("[::1]:47655")?.host, "::1")
        XCTAssertEqual(HostPort.parse("[::1]:47655")?.port, 47655)
        XCTAssertEqual(HostPort.parse("mac2.local:65535")?.port, 65535)
        XCTAssertNil(HostPort.parse("mac2.local"))
        XCTAssertNil(HostPort.parse("mac2.local:0"))
        XCTAssertNil(HostPort.parse("mac2.local:65536"))
        XCTAssertNil(HostPort.parse(""))
        XCTAssertNil(HostPort.parse(":80"))
    }

    func testHTTPCodec() throws {
        let body = Data("zip-bytes".utf8)
        let request = HTTPCodec.encode(
            startLine: "POST /v1/sessions HTTP/1.1",
            headers: [
                "Content-Type": "application/zip",
                "Content-Length": String(body.count),
                "X-Pairing-Code": "042013"
            ],
            body: body
        )
        let message = try XCTUnwrap(try HTTPCodec.decode(request, maxBodyBytes: 100))
        XCTAssertEqual(message.startLine, "POST /v1/sessions HTTP/1.1")
        XCTAssertEqual(message.headers["x-pairing-code"], "042013")
        XCTAssertEqual(message.body, body)
        XCTAssertNil(try HTTPCodec.decode(Data(request.dropLast()), maxBodyBytes: 100))

        let tooLarge = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.decode(tooLarge, maxBodyBytes: 10)) { error in
            XCTAssertEqual(error as? HTTPCodecError, .tooLarge)
        }
        let malformed = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.decode(malformed, maxBodyBytes: 10)) { error in
            XCTAssertEqual(error as? HTTPCodecError, .malformed)
        }
    }

    func testTokenNormalization() {
        XCTAssertEqual(
            SessionTransfer.normalizeToken("  rollout-2026-10-02T13-53-51-01A0FDC0-4569-7DA2-8A19-6C468980B706.jsonl "),
            "01a0fdc0-4569-7da2-8a19-6c468980b706"
        )
        XCTAssertEqual(
            SessionTransfer.normalizeToken("/tmp/sessions/rollout-2026-10-02T13-53-51-01a0fdc0-4569-7da2-8a19-6c468980b706.jsonl"),
            "01a0fdc0-4569-7da2-8a19-6c468980b706"
        )
        XCTAssertEqual(SessionTransfer.normalizeToken("Website"), "Website")
        XCTAssertEqual(SessionTransfer.normalizeToken("01A0FDC0-4569-7DA2-8A19-6C468980B706"), "01a0fdc0-4569-7da2-8a19-6c468980b706")
    }
}

private let stateSchema = [
    "PRAGMA journal_mode=WAL",
    """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY
    )
    """,
    """
    CREATE TABLE thread_sections (
      id TEXT PRIMARY KEY
    )
    """,
    """
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      title TEXT NOT NULL,
      name TEXT,
      project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
      thread_section_id TEXT REFERENCES thread_sections(id) ON DELETE SET NULL,
      created_at INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE thread_dynamic_tools (
      thread_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      name TEXT NOT NULL,
      payload BLOB,
      PRIMARY KEY (thread_id, position),
      FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
    )
    """
]

private let historySchema = [
    "PRAGMA journal_mode=WAL",
    """
    CREATE TABLE thread_turns (
      thread_id TEXT NOT NULL,
      turn_id TEXT NOT NULL,
      note TEXT,
      rollout_byte_offset INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE thread_items (
      thread_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      item_json TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE thread_history_projection_state (
      thread_id TEXT PRIMARY KEY,
      next_rollout_byte_offset INTEGER NOT NULL,
      next_rollout_ordinal INTEGER NOT NULL
    )
    """
]

extension SessionRoundTripTests {
    fileprivate func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-session-transfer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    fileprivate func relativePath(id: String? = nil) -> String {
        "sessions/2026/10/02/rollout-2026-10-02T13-53-51-\(id ?? threadID).jsonl"
    }

    fileprivate func seed(
        _ home: URL,
        title: String,
        includeThread: Bool = true,
        rolloutPath: String? = nil
    ) throws {
        try applySchema(stateSchema, to: home.appendingPathComponent("state_5.sqlite"))
        try applySchema(historySchema, to: home.appendingPathComponent("thread_history_1.sqlite"))
        guard includeThread else { return }
        let rollout = home.appendingPathComponent(relativePath())
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        if rolloutPath == nil {
            try rolloutBody.write(to: rollout)
        }
        let storedPath = rolloutPath ?? rollout.path
        let state = try SQLiteDB(url: home.appendingPathComponent("state_5.sqlite"), readonly: false)
        try state.run("INSERT INTO projects (id) VALUES (?)", [.text("p1")])
        try state.run("INSERT INTO thread_sections (id) VALUES (?)", [.text("s1")])
        try state.run(
            """
            INSERT INTO threads (id, rollout_path, title, name, project_id, thread_section_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(threadID),
                .text(storedPath),
                .text(title),
                .text("Website"),
                .text("p1"),
                .text("s1"),
                .int("1790963631")
            ]
        )
        try state.run(
            "INSERT INTO thread_dynamic_tools (thread_id, position, name, payload) VALUES (?, ?, ?, ?)",
            [.text(threadID), .int("0"), .text("demo"), .blob(blob.base64EncodedString())]
        )
        try state.run("PRAGMA wal_checkpoint(FULL)")
        let history = try SQLiteDB(url: home.appendingPathComponent("thread_history_1.sqlite"), readonly: false)
        try history.run(
            "INSERT INTO thread_turns (thread_id, turn_id, note, rollout_byte_offset) VALUES (?, ?, ?, ?)",
            [.text(threadID), .text("turn-1"), .null, .int(bigOffset)]
        )
        try history.run(
            "INSERT INTO thread_items (thread_id, item_id, item_json) VALUES (?, ?, ?)",
            [.text(threadID), .text("item-1"), .text("{\"type\":\"message\"}")]
        )
        try history.run(
            """
            INSERT INTO thread_history_projection_state
            (thread_id, next_rollout_byte_offset, next_rollout_ordinal)
            VALUES (?, ?, ?)
            """,
            [.text(threadID), .int(String(rolloutBody.count)), .int("1")]
        )
        try history.run("PRAGMA wal_checkpoint(FULL)")
    }

    fileprivate func makeDestination(_ home: URL, extraColumn: Bool = false) throws {
        try applySchema(stateSchema, to: home.appendingPathComponent("state_5.sqlite"))
        try applySchema(historySchema, to: home.appendingPathComponent("thread_history_1.sqlite"))
        let state = try SQLiteDB(url: home.appendingPathComponent("state_5.sqlite"), readonly: false)
        if extraColumn {
            try state.run("ALTER TABLE threads ADD COLUMN extra TEXT")
        }
        try state.run("INSERT INTO projects (id) VALUES (?)", [.text("p1")])
        try state.run("PRAGMA wal_checkpoint(FULL)")
    }

    fileprivate func applySchema(_ statements: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(url: url, readonly: false)
        for statement in statements {
            try db.run(statement)
        }
        try db.run("PRAGMA wal_checkpoint(FULL)")
    }
}
