import Foundation
import SQLite3

/// Builds the tree Cursor writes, synthetically.
///
/// The wire writer, the `BlobID` helper, and the `store.db` schema are ported
/// from `AgentSessionKitTests/CursorSessionAdapterTests.swift`'s
/// `CursorStoreFixture` — a test target cannot import another test target, and
/// a second copy of the SQLite bootstrap is cheaper than making the kit's
/// suite a library. The live half (`meta.json`, thin transcripts, worker pid
/// files, appending a turn) is new.
///
/// Nothing here comes off a real machine. Blob ids are made up — the reader
/// only needs a reference and a row to agree, never a true SHA-256 — every
/// path is under `/Users/example`, and every prompt was written for this file.
enum CursorFixture {
    // MARK: - Wire writer

    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0x7F {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining & 0x7F))
        return bytes
    }

    static func tag(_ field: UInt64, _ wire: UInt64) -> [UInt8] {
        varint((field << 3) | wire)
    }

    static func varintField(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    static func bytesField(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func stringField(_ field: UInt64, _ value: String) -> [UInt8] {
        bytesField(field, [UInt8](value.utf8))
    }

    /// A blob id as the 32 raw bytes a reference carries, plus the lowercase
    /// hex the `blobs` table is keyed by.
    struct BlobID: Hashable {
        let bytes: [UInt8]
        let hex: String

        init(seed: UInt8) {
            bytes = [UInt8](repeating: seed, count: 32)
            hex = bytes.map { String(format: "%02x", $0) }.joined()
        }

        /// The anchor a cursor persists for the message this blob *is*.
        var anchor: String { "\(hex).0" }
    }

    /// A node: the workspace URI, surface, timestamp, references to its
    /// messages, and any messages inlined instead of referenced.
    static func node(
        references: [BlobID] = [],
        inlineMessages: [String] = [],
        workspaceURI: String? = nil,
        surface: String? = nil,
        timestampMillis: UInt64? = nil
    ) -> Data {
        var out: [UInt8] = []
        for reference in references {
            out += bytesField(1, reference.bytes)
        }
        for message in inlineMessages {
            out += stringField(4, message)
        }
        if let workspaceURI { out += stringField(9, workspaceURI) }
        if let surface { out += stringField(22, surface) }
        if let timestampMillis { out += varintField(26, timestampMillis) }
        return Data(out)
    }

    // MARK: - Messages

    /// The `<timestamp>` header Cursor prefixes a prompt with.
    static let promptStamp = "Tuesday, Aug 18, 2026, 5:39 PM (UTC+8)"

    /// The instant ``promptStamp`` names: 2026-08-18 09:39:00Z.
    static let promptStampDate = Date(timeIntervalSince1970: 1_787_045_940)

    /// A prompt in the envelope Cursor wraps one in.
    static func promptText(_ body: String, stamp: String? = promptStamp) -> String {
        let header = stamp.map { "<timestamp>\($0)</timestamp>\n" } ?? ""
        return "\(header)<user_query>\n\(body)\n</user_query>"
    }

    static func userMessage(_ body: String, stamp: String? = promptStamp) -> String {
        json([
            "role": "user",
            "content": [["type": "text", "text": promptText(body, stamp: stamp)]]
        ])
    }

    static func assistantMessage(_ parts: [[String: Any]], model: String? = nil) -> String {
        var content = parts
        if let model, !content.isEmpty {
            content[content.count - 1]["providerOptions"] = ["cursor": ["modelName": model]]
        }
        return json(["role": "assistant", "id": "msg_fixture", "content": content])
    }

    static func textPart(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func reasoningPart(_ text: String = "weighing two options") -> [String: Any] {
        ["type": "reasoning", "text": text]
    }

    static func toolCallPart(id: String, name: String, args: [String: Any]) -> [String: Any] {
        ["type": "tool-call", "toolCallId": id, "toolName": name, "args": args]
    }

    static func toolResultMessage(id: String, result: Any, isError: Bool = false) -> String {
        var part: [String: Any] = ["type": "tool-result", "toolCallId": id, "result": result]
        if isError { part["isError"] = true }
        return json(["role": "tool", "content": [part]])
    }

    static func systemMessage(_ text: String) -> String {
        json(["role": "system", "content": [["type": "text", "text": text]]])
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func hexEncoded(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The store

    struct Blob {
        let id: BlobID
        let data: Data

        init(id: BlobID, data: Data) {
            self.id = id
            self.data = data
        }

        init(id: BlobID, message: String) {
            self.id = id
            self.data = Data(message.utf8)
        }
    }

    /// The card the `meta` table's row `'0'` holds, hex-encoded.
    static func card(
        agentID: String,
        root: BlobID?,
        name: String? = "Wire up the reducer",
        mode: String? = "agent",
        createdAtMillis: Int = 1_787_040_000_000
    ) -> [String: Any] {
        var object: [String: Any] = ["agentId": agentID, "createdAt": createdAtMillis]
        if let root { object["latestRootBlobId"] = root.hex }
        if let name { object["name"] = name }
        if let mode { object["mode"] = mode }
        return object
    }

    /// `~/.cursor/chats/<workspace hash>/<agent id>/store.db`.
    @discardableResult
    static func writeStore(
        home: URL,
        agentID: String,
        workspaceHash: String = "0af52b5f862f8eb7689b0795c4f131f8",
        card: [String: Any],
        metaKey: String = "0",
        metaValue: String? = nil,
        blobs: [Blob],
        walMode: Bool = false
    ) throws -> URL {
        let directory = home
            .appendingPathComponent(".cursor/chats", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.db")

        let database = try open(url, create: true)
        defer { sqlite3_close_v2(database) }
        if walMode {
            sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        let schema = """
            CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        try upsertMeta(database, key: metaKey, value: metaValue ?? hexEncoded(json(card)))
        for blob in blobs { try insertBlob(database, id: blob.id.hex, data: blob.data) }
        return url
    }

    /// Adds blobs and moves `latestRootBlobId` — one more turn, the way Cursor
    /// writes one.
    static func appendTurn(
        store: URL,
        card: [String: Any],
        blobs: [Blob],
        metaKey: String = "0"
    ) throws {
        let database = try open(store, create: false)
        defer { sqlite3_close_v2(database) }
        for blob in blobs { try insertBlob(database, id: blob.id.hex, data: blob.data) }
        try upsertMeta(database, key: metaKey, value: hexEncoded(json(card)))
    }

    private static func open(_ url: URL, create: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        return database
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func upsertMeta(_ database: OpaquePointer, key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", -1, &statement, nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func insertBlob(_ database: OpaquePointer, id: String, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "INSERT OR REPLACE INTO blobs(id, data) VALUES(?, ?)", -1, &statement, nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - The rest of the tree

    /// `meta.json`, beside the store.
    @discardableResult
    static func writeAgentMeta(
        home: URL,
        agentID: String,
        workspaceHash: String = "0af52b5f862f8eb7689b0795c4f131f8",
        cwd: String?,
        updatedAt: Date = Date(),
        hasConversation: Bool = true
    ) throws -> URL {
        var object: [String: Any] = [
            "schemaVersion": 3,
            "createdAtMs": Int(updatedAt.timeIntervalSince1970 * 1000) - 60_000,
            "updatedAtMs": Int(updatedAt.timeIntervalSince1970 * 1000),
            "hasConversation": hasConversation
        ]
        if let cwd { object["cwd"] = cwd }
        let url = home
            .appendingPathComponent(".cursor/chats", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json(object).utf8).write(to: url)
        return url
    }

    /// `~/.cursor/projects/<slug>/agent-transcripts/<agent id>/<agent id>.jsonl`.
    @discardableResult
    static func writeThinTranscript(
        home: URL,
        slug: String,
        agentID: String,
        lines: [String]
    ) throws -> URL {
        let url = home
            .appendingPathComponent(".cursor/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("\(agentID).jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }

    static func transcriptUserLine(_ body: String, stamp: String? = promptStamp) -> String {
        json(["role": "user", "message": ["content": [["type": "text", "text": promptText(body, stamp: stamp)]]]])
    }

    static func transcriptAssistantLine(_ text: String) -> String {
        json(["role": "assistant", "message": ["content": [["type": "text", "text": text]]]])
    }

    static func transcriptTurnEnded(_ status: String = "success") -> String {
        json(["type": "turn_ended", "status": status])
    }

    /// A `worker.sock` that is only a file — the stale case, which is what a
    /// worker that crashed leaves behind.
    @discardableResult
    static func writeWorkerSocketFile(home: URL, slug: String) throws -> URL {
        let url = home
            .appendingPathComponent(".cursor/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("worker.sock")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: url)
        return url
    }

    /// `cursor-agent-worker-<worker id>.pid` in the extension's global storage.
    @discardableResult
    static func writeWorkerPID(home: URL, workerID: String, pid: pid_t) throws -> URL {
        let url = home
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker",
                isDirectory: true
            )
            .appendingPathComponent("cursor-agent-worker-\(workerID).pid")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("\(pid)\n".utf8).write(to: url)
        return url
    }

    /// Backdates a file, so an age-based branch can be driven without waiting.
    static func backdate(_ path: String, by seconds: TimeInterval) {
        let when = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
    }
}
