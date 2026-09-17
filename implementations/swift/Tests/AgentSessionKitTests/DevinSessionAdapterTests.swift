import XCTest
import SQLite3
@testable import AgentSessionKit

/// Builds `~/.local/share/devin/cli/sessions.db` with the tables and columns
/// the Devin CLI creates. Every row is synthetic.
enum DevinStoreFixture {
    struct Session {
        var id: String
        var workingDirectory = "/Users/example/proj"
        var model = "swe-2-high"
        var createdAt: Int64 = 1_767_225_600
        var lastActivityAt: Int64 = 1_767_225_630
        var title: String?
        var mainChainID: Int64?
        var hidden: Int64 = 0
    }

    struct Node {
        var sessionID: String
        var nodeID: Int64
        var parentNodeID: Int64?
        var chatMessage: String
        var createdAt: Int64 = 1_767_225_640
    }

    static let schema = """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          working_directory TEXT NOT NULL,
          backend_type TEXT NOT NULL,
          model TEXT NOT NULL,
          agent_mode TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
          shell_last_seen_index INTEGER DEFAULT 0, cogs_json TEXT, workspace_dirs TEXT,
          hidden INTEGER NOT NULL DEFAULT 0, metadata TEXT);
        CREATE INDEX idx_sessions_activity ON sessions(last_activity_at DESC);
        CREATE TABLE message_nodes (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          node_id INTEGER NOT NULL,
          parent_node_id INTEGER,
          chat_message TEXT NOT NULL,
          created_at INTEGER NOT NULL, metadata TEXT,
          FOREIGN KEY (session_id) REFERENCES sessions(id),
          UNIQUE(session_id, node_id)
        );
        CREATE INDEX idx_message_nodes_session ON message_nodes(session_id);
        CREATE TABLE subagent_heads (
            session_id    TEXT    NOT NULL,
            agent_id      TEXT    NOT NULL,
            chain_node_id INTEGER NOT NULL,
            updated_at    INTEGER NOT NULL,
            PRIMARY KEY (session_id, agent_id)
        );
        """

    static func databaseURL(home: URL) -> URL {
        home.appendingPathComponent(".local/share/devin/cli/sessions.db")
    }

    /// Writes the store in WAL mode, as the CLI keeps it.
    @discardableResult
    static func write(home: URL, sessions: [Session], nodes: [Node]) throws -> URL {
        let url = databaseURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let database = try open(url)
        defer { sqlite3_close_v2(database) }
        try exec(database, "PRAGMA journal_mode=WAL")
        try exec(database, schema)
        for session in sessions { try insert(database, session) }
        for node in nodes { try insert(database, node) }
        return url
    }

    static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database
        else { throw CocoaError(.fileWriteUnknown) }
        return database
    }

    static func exec(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func insert(_ database: OpaquePointer, _ session: Session) throws {
        try run(database, """
            INSERT INTO sessions(id, working_directory, backend_type, model, agent_mode, created_at,
                                 last_activity_at, title, main_chain_id, hidden, metadata)
            VALUES(?, ?, 'windsurf', ?, 'smart', ?, ?, ?, ?, ?, '{"total_credit_cost":0,"total_acu_cost":0.0}')
            """, [
                .text(session.id), .text(session.workingDirectory), .text(session.model),
                .int(session.createdAt), .int(session.lastActivityAt),
                session.title.map(Value.text) ?? .null, session.mainChainID.map(Value.int) ?? .null,
                .int(session.hidden)
            ])
    }

    static func insert(_ database: OpaquePointer, _ node: Node) throws {
        try run(database, """
            INSERT INTO message_nodes(session_id, node_id, parent_node_id, chat_message, created_at)
            VALUES(?, ?, ?, ?, ?)
            """, [
                .text(node.sessionID), .int(node.nodeID), node.parentNodeID.map(Value.int) ?? .null,
                .text(node.chatMessage), .int(node.createdAt)
            ])
    }

    enum Value {
        case text(String)
        case int(Int64)
        case null
    }

    static func run(_ database: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - chat_message JSON

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func system(_ text: String) -> String {
        json(["message_id": UUID().uuidString.lowercased(), "role": "system", "content": text,
              "metadata": ["num_tokens": 12, "request_id": ""]])
    }

    static func user(_ text: String, typed: Bool = true, at iso: String = "2026-01-01T00:00:10.123456Z") -> String {
        json(["message_id": UUID().uuidString.lowercased(), "role": "user", "content": text,
              "metadata": ["is_user_input": typed, "created_at": iso]])
    }

    static func assistant(
        _ text: String,
        model: String? = "swe-2-high-20260101",
        toolCalls: [[String: Any]] = [],
        at iso: String = "2026-01-01T00:00:20.654321Z"
    ) -> String {
        var metadata: [String: Any] = [
            "created_at": iso,
            "finish_reason": "stop",
            "metrics": ["input_tokens": 1_200, "output_tokens": 80, "cache_read_tokens": 900]
        ]
        if let model { metadata["generation_model"] = model }
        return json([
            "message_id": UUID().uuidString.lowercased(),
            "role": "assistant",
            "content": text,
            "thinking": ["thinking": "private reasoning", "signature": "sealed.v1.example", "signature_type": "x"],
            "tool_calls": toolCalls,
            "metadata": metadata
        ])
    }

    static func tool(_ text: String, callID: String) -> String {
        json(["role": "tool", "content": text, "tool_call_id": callID, "metadata": [:]])
    }
}

final class DevinSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = DevinSessionAdapter()
    private typealias Fixture = DevinStoreFixture

    private let sessionID = "quiet-harbor"
    private let olderID = "amber-lantern"
    private let hiddenID = "silent-summary"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKDevinSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// A compacted conversation: an abandoned pre-compaction prefix, the
    /// re-rooted main chain with system blocks and an injected reminder, a
    /// discarded sibling reply, and a sub-agent's tree of its own.
    private var forest: [Fixture.Node] {
        let call: [String: Any] = ["id": "call_1", "name": "read", "arguments": ["path": "NOTES.md"]]
        return [
            .init(sessionID: sessionID, nodeID: 0, parentNodeID: nil, chatMessage: Fixture.system("Old prefix")),
            .init(sessionID: sessionID, nodeID: 1, parentNodeID: 0, chatMessage: Fixture.user("Count the lines in NOTES.md")),
            .init(sessionID: sessionID, nodeID: 2, parentNodeID: nil, chatMessage: Fixture.system("You are a coding agent.")),
            .init(sessionID: sessionID, nodeID: 3, parentNodeID: 2, chatMessage: Fixture.system("<system_info>example</system_info>")),
            .init(sessionID: sessionID, nodeID: 4, parentNodeID: 3, chatMessage: Fixture.user("Count the lines in NOTES.md")),
            .init(sessionID: sessionID, nodeID: 5, parentNodeID: 4, chatMessage: Fixture.system("<available_skills/>")),
            .init(sessionID: sessionID, nodeID: 6, parentNodeID: 5,
                  chatMessage: Fixture.user("<reminder>stay in the workspace</reminder>", typed: false)),
            .init(sessionID: sessionID, nodeID: 7, parentNodeID: 6,
                  chatMessage: Fixture.assistant("I'll read it.", toolCalls: [call])),
            .init(sessionID: sessionID, nodeID: 8, parentNodeID: 7, chatMessage: Fixture.tool("1|# Notes", callID: "call_1")),
            .init(sessionID: sessionID, nodeID: 9, parentNodeID: 8, chatMessage: Fixture.assistant("A discarded draft")),
            .init(sessionID: sessionID, nodeID: 10, parentNodeID: 8,
                  chatMessage: Fixture.assistant("NOTES.md has one line.", model: "swe-2-high-20260102")),
            .init(sessionID: sessionID, nodeID: 11, parentNodeID: nil, chatMessage: Fixture.system("Sub-agent prompt")),
            .init(sessionID: sessionID, nodeID: 12, parentNodeID: 11, chatMessage: Fixture.user("Sub-agent task"))
        ]
    }

    private var olderNodes: [Fixture.Node] {
        [
            .init(sessionID: olderID, nodeID: 0, parentNodeID: nil, chatMessage: Fixture.system("You are a coding agent.")),
            .init(sessionID: olderID, nodeID: 1, parentNodeID: 0, chatMessage: Fixture.user("Rename the target")),
            .init(sessionID: olderID, nodeID: 2, parentNodeID: 1, chatMessage: Fixture.assistant("Renamed.", model: nil))
        ]
    }

    private var sessions: [Fixture.Session] {
        [
            .init(id: sessionID, title: "Notes line count", mainChainID: 10),
            .init(id: olderID, workingDirectory: "/Users/example/other", model: "swe-2",
                  createdAt: 1_767_000_000, lastActivityAt: 1_767_000_060, title: nil, mainChainID: nil),
            .init(id: hiddenID, lastActivityAt: 1_767_225_900, title: "Summarize", mainChainID: nil, hidden: 1)
        ]
    }

    @discardableResult
    private func writeStore(
        sessions: [Fixture.Session]? = nil,
        nodes: [Fixture.Node]? = nil
    ) throws -> URL {
        try Fixture.write(home: home, sessions: sessions ?? self.sessions, nodes: nodes ?? forest + olderNodes)
    }

    private func locator(_ id: String) -> URL {
        DevinSessionAdapter.sessionURL(database: Fixture.databaseURL(home: home), sessionID: id)
    }

    // MARK: - Discovery

    func testDiscoveryListsVisibleSessionsMostRecentFirst() throws {
        let database = try writeStore()
        let files = adapter.discoverSessionFiles(homeDirectory: home.path)
        XCTAssertEqual(files.map(\.lastPathComponent), [sessionID, olderID])
        XCTAssertEqual(Set(files.map { $0.deletingLastPathComponent().path }), [database.path])
        XCTAssertEqual(adapter.discoverSessions(homeDirectory: home.path).map(\.sessionID), [sessionID, olderID])
    }

    func testDiscoveryToleratesAMissingStore() {
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path), [])
    }

    func testDiscoveryIgnoresASymlinkedDatabase() throws {
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try Fixture.write(home: elsewhere, sessions: sessions, nodes: forest)
        let link = Fixture.databaseURL(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Fixture.databaseURL(home: elsewhere))

        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path), [])
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: locator(sessionID)))
    }

    func testRootIsTheDevinCLIDirectory() {
        XCTAssertEqual(adapter.roots(homeDirectory: "/Users/example").map(\.path),
                       ["/Users/example/.local/share/devin/cli"])
        XCTAssertEqual(DevinSessionAdapter.databaseURL(homeDirectory: "/Users/example").path,
                       "/Users/example/.local/share/devin/cli/sessions.db")
    }

    // MARK: - Metadata

    func testMetadataReadsTheSessionRowAndTheMainChain() throws {
        try writeStore()
        let summary = try adapter.extractMetadata(fileURL: locator(sessionID))

        XCTAssertEqual(summary.provider, .devin)
        XCTAssertEqual(summary.harness, .devin)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.title, "Notes line count")
        XCTAssertEqual(summary.summary, "NOTES.md has one line.")
        // The model that generated the latest reply wins over the session's setting.
        XCTAssertEqual(summary.model, "swe-2-high-20260102")
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(summary.lastActiveAt, Date(timeIntervalSince1970: 1_767_225_630))
        XCTAssertEqual(summary.sourcePath, locator(sessionID).path)
        XCTAssertGreaterThan(summary.sizeBytes, 0)
        XCTAssertFalse(summary.hasKnownMessageCount)
    }

    func testTitleFallsBackToTheFirstTypedPromptAndModelToTheSessionRow() throws {
        try writeStore()
        let summary = try adapter.extractMetadata(fileURL: locator(olderID))
        XCTAssertEqual(summary.title, "Rename the target")
        XCTAssertEqual(summary.summary, "Renamed.")
        XCTAssertEqual(summary.model, "swe-2")
        XCTAssertEqual(summary.projectDir, "/Users/example/other")
    }

    /// A newest reply without a `generation_model` does not borrow an older
    /// response's model, which may predate a model switch.
    func testTheNewestReplyWithoutAModelFallsBackToTheSessionRow() throws {
        let nodes: [Fixture.Node] = [
            .init(sessionID: olderID, nodeID: 0, parentNodeID: nil, chatMessage: Fixture.user("Rename the target")),
            .init(sessionID: olderID, nodeID: 1, parentNodeID: 0,
                  chatMessage: Fixture.assistant("Looking.", model: "swe-1.6")),
            .init(sessionID: olderID, nodeID: 2, parentNodeID: 1, chatMessage: Fixture.assistant("Renamed.", model: nil))
        ]
        try writeStore(nodes: nodes)
        let summary = try adapter.extractMetadata(fileURL: locator(olderID))
        XCTAssertEqual(summary.summary, "Renamed.")
        XCTAssertEqual(summary.model, "swe-2")
    }

    /// An injected user turn is not the session's first prompt.
    func testTitleSkipsInjectedAndSystemTurns() throws {
        let nodes: [Fixture.Node] = [
            .init(sessionID: olderID, nodeID: 0, parentNodeID: nil, chatMessage: Fixture.system("You are a coding agent.")),
            .init(sessionID: olderID, nodeID: 1, parentNodeID: 0, chatMessage: Fixture.user("<hook>context</hook>", typed: false)),
            .init(sessionID: olderID, nodeID: 2, parentNodeID: 1, chatMessage: Fixture.user("Fix the flaky test"))
        ]
        try writeStore(sessions: [.init(id: olderID, title: nil, mainChainID: 2)], nodes: nodes)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: locator(olderID)).title, "Fix the flaky test")
    }

    func testHiddenSessionsAreNotListedAndTheirMetadataIsRefused() throws {
        try writeStore()
        XCTAssertFalse(adapter.discoverSessionFiles(homeDirectory: home.path).map(\.lastPathComponent).contains(hiddenID))
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: locator(hiddenID))) { error in
            guard case SessionParseError.invalidFormat = error else { return XCTFail("got \(error)") }
        }
    }

    func testUnknownSessionsAndForeignURLsAreInvalidFormat() throws {
        try writeStore()
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: locator("no-such-session"))) { error in
            guard case SessionParseError.invalidFormat = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: Fixture.databaseURL(home: home))) { error in
            guard case SessionParseError.invalidFormat = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try adapter.parseTranscript(fileURL: locator("no-such-session")))
    }

    func testAMissingDatabaseIsUnreadable() {
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: locator(sessionID))) { error in
            guard case SessionParseError.unreadable = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - Transcript

    func testTranscriptFollowsTheMainChainOnly() throws {
        try writeStore()
        let document = try adapter.parseTranscript(fileURL: locator(sessionID))

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        XCTAssertEqual(document.messages.map(\.text), [
            "Count the lines in NOTES.md",
            "I'll read it.",
            "[Tool: read]\n{\"path\":\"NOTES.md\"}",
            "1|# Notes",
            "NOTES.md has one line."
        ])
        XCTAssertEqual(document.messages.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertFalse(document.truncated)
        // The message's own stamp, not the row's (re)write time.
        let userStamp = try XCTUnwrap(document.messages.first?.timestamp)
        XCTAssertEqual(userStamp.timeIntervalSince1970, 1_767_225_610.123, accuracy: 0.001)
        XCTAssertFalse(document.messages.contains { $0.text.contains("private reasoning") })
    }

    func testTranscriptRangesSlice() throws {
        try writeStore()
        let document = try adapter.parseTranscript(fileURL: locator(sessionID), range: 1..<3)
        XCTAssertEqual(document.messages.map(\.text), ["I'll read it.", "[Tool: read]\n{\"path\":\"NOTES.md\"}"])
        XCTAssertEqual(document.totalMessageCount, 5)
    }

    /// With no `main_chain_id`, the newest node is the tip — Devin's own fallback.
    func testMissingMainChainFallsBackToTheNewestNode() throws {
        try writeStore()
        XCTAssertEqual(
            try adapter.parseTranscript(fileURL: locator(olderID)).messages.map(\.text),
            ["Rename the target", "Renamed."]
        )
    }

    func testAMainChainNamingAMissingNodeFallsBackToo() throws {
        try writeStore(sessions: [.init(id: olderID, title: nil, mainChainID: 99)], nodes: olderNodes)
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator(olderID)).messages.count, 2)
    }

    func testDanglingParentsAndCyclesEndTheWalk() throws {
        let nodes: [Fixture.Node] = [
            .init(sessionID: olderID, nodeID: 1, parentNodeID: 2, chatMessage: Fixture.user("First")),
            .init(sessionID: olderID, nodeID: 2, parentNodeID: 1, chatMessage: Fixture.assistant("Second")),
            .init(sessionID: olderID, nodeID: 5, parentNodeID: 40, chatMessage: Fixture.user("Orphan")),
            .init(sessionID: olderID, nodeID: 6, parentNodeID: 5, chatMessage: Fixture.assistant("Reply"))
        ]
        try writeStore(sessions: [.init(id: olderID, title: nil, mainChainID: 2)], nodes: nodes)
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator(olderID)).messages.map(\.text), ["First", "Second"])

        try FileManager.default.removeItem(at: home.appendingPathComponent(".local"))
        try writeStore(sessions: [.init(id: olderID, title: nil, mainChainID: 6)], nodes: nodes)
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator(olderID)).messages.map(\.text), ["Orphan", "Reply"])
    }

    func testMalformedMessagesAreSkipped() throws {
        let nodes: [Fixture.Node] = [
            .init(sessionID: olderID, nodeID: 0, parentNodeID: nil, chatMessage: Fixture.user("Keep this")),
            .init(sessionID: olderID, nodeID: 1, parentNodeID: 0, chatMessage: "{not json"),
            .init(sessionID: olderID, nodeID: 2, parentNodeID: 1, chatMessage: "[]"),
            .init(sessionID: olderID, nodeID: 3, parentNodeID: 2, chatMessage: Fixture.json(["role": "narrator", "content": "?"])),
            .init(sessionID: olderID, nodeID: 4, parentNodeID: 3, chatMessage: Fixture.assistant("And this"))
        ]
        try writeStore(sessions: [.init(id: olderID, title: nil, mainChainID: 4)], nodes: nodes)
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator(olderID)).messages.map(\.text), ["Keep this", "And this"])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: locator(olderID)).title, "Keep this")
    }

    func testToolCallsInEitherSpellingRender() {
        XCTAssertEqual(
            DevinSessionAdapter.toolCallText(["name": "exec", "arguments": "{\"cmd\":\"ls\"}"]),
            "[Tool: exec]\n{\"cmd\":\"ls\"}"
        )
        XCTAssertEqual(
            DevinSessionAdapter.toolCallText(["function": ["name": "grep", "arguments": ["q": "x"]]]),
            "[Tool: grep]\n{\"q\":\"x\"}"
        )
        XCTAssertEqual(DevinSessionAdapter.toolCallText([:]), "[Tool: tool]")
    }

    // MARK: - Change fingerprint

    func testChangeFingerprintMovesPerSession() throws {
        let database = try writeStore()
        let first = try XCTUnwrap(adapter.changeFingerprint(fileURL: locator(sessionID)))
        let older = try XCTUnwrap(adapter.changeFingerprint(fileURL: locator(olderID)))
        XCTAssertEqual(adapter.changeFingerprint(fileURL: locator(sessionID)), first, "stable across reads")
        XCTAssertNotEqual(first, older)

        let writer = try Fixture.open(database)
        defer { sqlite3_close_v2(writer) }
        try Fixture.insert(writer, .init(sessionID: olderID, nodeID: 3, parentNodeID: 2, chatMessage: Fixture.user("More")))
        try Fixture.exec(writer, "UPDATE sessions SET main_chain_id = 3 WHERE id = '\(olderID)'")

        XCTAssertEqual(adapter.changeFingerprint(fileURL: locator(sessionID)), first, "an untouched session does not move")
        XCTAssertNotEqual(adapter.changeFingerprint(fileURL: locator(olderID)), older)

        // A title generated after the fact moves it too, with no new node.
        try Fixture.exec(writer, "UPDATE sessions SET title = 'Renamed' WHERE id = '\(sessionID)'")
        XCTAssertNotEqual(adapter.changeFingerprint(fileURL: locator(sessionID)), first)
        XCTAssertNil(adapter.changeFingerprint(fileURL: locator("no-such-session")))
    }

    /// A wrapper that does not forward `changeFingerprint` still indexes Devin
    /// sessions, through the store's own fingerprint.
    func testTheDefaultFingerprintFallsBackToTheStoreFile() throws {
        let database = try writeStore()
        let store = try XCTUnwrap(SessionChangeFingerprint.file(at: database))
        XCTAssertEqual(SessionChangeFingerprint.file(at: locator(sessionID)), store)
        XCTAssertNil(SessionChangeFingerprint.file(at: home.appendingPathComponent("missing/file.jsonl")))
    }

    // MARK: - Never writing

    /// The CLI's last connection removes `-wal` and `-shm` when it closes
    /// cleanly. A read-only connection cannot recreate them, and must not
    /// need to: every read works and leaves the directory as it found it.
    func testReadsOfAClosedStoreLeaveNoJournalBehind() throws {
        let database = try writeStore()
        let writer = try Fixture.open(database)
        try Fixture.exec(writer, "PRAGMA wal_checkpoint(TRUNCATE)")
        sqlite3_close_v2(writer)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: database.deletingLastPathComponent().path)

        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 2)
        XCTAssertNotNil(adapter.changeFingerprint(fileURL: locator(sessionID)))
        XCTAssertEqual(try adapter.extractMetadata(fileURL: locator(sessionID)).title, "Notes line count")
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator(sessionID)).messages.count, 5)

        let after = try FileManager.default.contentsOfDirectory(atPath: database.deletingLastPathComponent().path)
        XCTAssertEqual(after.sorted(), before.sorted())
        XCTAssertEqual(before, ["sessions.db"])
    }

    /// While the CLI holds the store open, committed rows may live only in
    /// `-wal`; they are read through it.
    func testRowsStillInTheWALAreRead() throws {
        let database = try writeStore()
        let writer = try Fixture.open(database)
        defer { sqlite3_close_v2(writer) }
        try Fixture.exec(writer, "PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(writer, Fixture.Session(id: "fresh-meadow", lastActivityAt: 1_767_300_000, title: "Brand new"))

        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).first?.lastPathComponent, "fresh-meadow")
        XCTAssertEqual(try adapter.extractMetadata(fileURL: locator("fresh-meadow")).title, "Brand new")
        XCTAssertEqual(try adapter.parseTranscript(fileURL: locator("fresh-meadow")).messages, [])
    }

    // MARK: - The index

    func testTheIndexKeysEverySessionInTheStoreSeparately() async throws {
        let database = try writeStore()
        let store = try SessionIndexStore(url: home.appendingPathComponent("index/session_index.sqlite3"))
        let service = SessionIndexService(
            homeDirectory: home.path,
            store: store,
            registry: SessionProviderRegistry(adapters: [adapter]),
            bodyIndexing: { true }
        )

        await service.refreshIndex()
        var summaries = try await store.allSummaries()
        XCTAssertEqual(Set(summaries.map(\.sessionID)), [sessionID, olderID])
        XCTAssertEqual(summaries.first { $0.sessionID == sessionID }?.harness, .devin)
        let hits = try await service.search("one line", providers: [.devin])
        XCTAssertEqual(hits.map(\.summary.sessionID), [sessionID])

        let writer = try Fixture.open(database)
        try Fixture.exec(writer, "UPDATE sessions SET title = 'Renamed later' WHERE id = '\(olderID)'")
        sqlite3_close_v2(writer)

        await service.refreshIndex()
        summaries = try await store.allSummaries()
        XCTAssertEqual(summaries.first { $0.sessionID == olderID }?.title, "Renamed later")
        XCTAssertEqual(summaries.first { $0.sessionID == sessionID }?.title, "Notes line count")
    }

    // MARK: - Deletion, registry, resume

    func testDeletionIsRefused() throws {
        try writeStore()
        let summary = try adapter.extractMetadata(fileURL: locator(sessionID))
        XCTAssertFalse(SessionProvider.devin.supportsDeletion)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.devin))
        }
    }

    func testStandardRegistryCarriesTheAdapter() {
        let registry = SessionProviderRegistry.standard(homeDirectory: "/Users/example")
        XCTAssertTrue(registry.adapter(for: .devin) is DevinSessionAdapter)
        XCTAssertEqual(SessionProvider.devin.defaultHarness, .devin)
    }

    func testResumeCommand() throws {
        XCTAssertEqual(
            try SessionResumeCommandBuilder.command(provider: .devin, sessionID: sessionID),
            "devin --resume \(sessionID)"
        )
    }
}
