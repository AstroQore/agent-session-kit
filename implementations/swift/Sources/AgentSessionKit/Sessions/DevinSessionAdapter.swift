import Foundation
import SQLite3

/// Devin sessions: every conversation the `devin` CLI and the Devin desktop
/// app run lives in **one** SQLite database,
/// `~/.local/share/devin/cli/sessions.db`, which the CLI keeps open in WAL
/// mode. The desktop app's "Devin Local" agent drives that same CLI over ACP,
/// so both surfaces land in the same rows and are one harness.
///
/// Two tables matter:
///
/// - `sessions(id, working_directory, model, created_at, last_activity_at,
///   title, main_chain_id, hidden, …)` — one row per session, timestamps in
///   unix seconds. `hidden = 1` marks sessions Devin's own helper agents (the
///   summarizer, for one) persist; Devin keeps them out of every user-facing
///   list, and so does this adapter.
/// - `message_nodes(session_id, node_id, parent_node_id, chat_message,
///   created_at, …)` — a *forest* per session. Compaction re-roots the system
///   prefix, a retry adds a sibling, and every sub-agent's chain is a tree of
///   its own. `sessions.main_chain_id` is the node id of the conversation's
///   current tip; walking `parent_node_id` up from it to a root and reversing
///   is the conversation as the model last saw it, and the only branch this
///   adapter reads.
///
/// **One store, many sessions.** The adapter protocol is per file, so a
/// session is addressed by a locator *inside* the database —
/// `<…>/sessions.db/<session id>` — that is never a real path.
/// `discoverSessionFiles` lists one locator per visible row, the index keys
/// each one separately, and `changeFingerprint` answers per session (its
/// activity stamp, node count, highest node row, tip, title), so a turn in
/// one conversation re-reads that conversation and not every other one.
///
/// Every read opens the database read-only through `LiveSQLiteReader` and
/// closes it before returning; nothing holds it open between calls, and
/// nothing is ever written. **Read-only, permanently**: removing a session
/// means deleting rows from five tables of a database another process has
/// open, which is `devin rm`'s job, not this package's.
public struct DevinSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .devin

    public init() {}

    static let storeDirectory = ".local/share/devin/cli"
    static let databaseFileName = "sessions.db"

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(Self.storeDirectory, isDirectory: true)]
    }

    /// The one database every session lives in.
    public static func databaseURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(storeDirectory, isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    /// The locator `discoverSessionFiles` hands out for `sessionID`:
    /// `<database>/<session id>`. It names a row, not a file.
    public static func sessionURL(database: URL, sessionID: String) -> URL {
        database.appendingPathComponent(sessionID, isDirectory: false)
    }

    // MARK: - Limits

    /// Sessions listed from one database, most recently active first.
    static let maxSessions = 10_000
    /// Nodes followed up one main chain. A chain past this keeps its newest
    /// nodes and the transcript says it was truncated.
    static let maxChainNodes = 20_000
    /// Message bytes decoded for one transcript, oldest first.
    static let maxTranscriptBytes = 32 * 1024 * 1024
    /// Nodes read from the root while looking for the first prompt, and from
    /// the tip while looking for the last reply. System-prefix nodes come
    /// first on every chain, so the head window has to clear them.
    static let headScanNodes = 64
    static let tailScanNodes = 32

    // MARK: - Discovery

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        let database = Self.databaseURL(homeDirectory: homeDirectory)
        guard Self.isRegularFile(database) else { return [] }
        let ids = LiveSQLiteReader.read(at: database) { handle in
            try Self.visibleSessionIDs(handle)
        } ?? []
        return ids.filter(Self.isUsableSessionID).map {
            Self.sessionURL(database: database, sessionID: $0)
        }
    }

    /// Not a symlink, and a regular file. A link here could resolve anywhere.
    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        return values?.isSymbolicLink == false && values?.isRegularFile == true
    }

    /// A session id that can be one path component of a locator.
    static func isUsableSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id != "." && id != ".." && !id.contains("/")
            && !id.unicodeScalars.contains { $0.value < 0x20 }
    }

    /// `(database, session id)` for a locator, or `nil` for anything else.
    static func locate(_ url: URL) -> (database: URL, sessionID: String)? {
        let database = url.deletingLastPathComponent()
        let sessionID = url.lastPathComponent
        guard database.lastPathComponent == databaseFileName, isUsableSessionID(sessionID) else {
            return nil
        }
        return (database, sessionID)
    }

    // MARK: - Change fingerprint

    /// Per session, not per database: the session's `last_activity_at`
    /// (seconds, stored as nanoseconds) and a stable hash of what else moves
    /// when a conversation changes — its node count, its highest node row
    /// (rows are `AUTOINCREMENT`, so a replaced node always gets a new one),
    /// its tip, its title, and its `hidden` flag.
    ///
    /// No snapshot fallback: this runs once per session per refresh against
    /// a database every session shares, so a store that cannot be read right
    /// now is skipped (`nil`) and asked again on the next pass rather than
    /// copied once per session.
    public func changeFingerprint(fileURL: URL) -> SessionChangeFingerprint? {
        guard let (database, sessionID) = Self.locate(fileURL), Self.isRegularFile(database) else {
            return nil
        }
        let probe = LiveSQLiteReader.read(at: database, snapshotFallback: false) { handle in
            try Self.fingerprint(handle, sessionID: sessionID)
        }
        return probe ?? nil
    }

    static func fingerprint(_ handle: OpaquePointer, sessionID: String) throws -> SessionChangeFingerprint? {
        guard let row = try sessionRow(handle, sessionID: sessionID) else { return nil }
        let statement = try LiveSQLiteReader.prepare(
            handle,
            "SELECT COUNT(*), COALESCE(MAX(row_id), 0) FROM message_nodes WHERE session_id = ?1"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw LiveSQLiteReader.ReadError.statement }
        let marker = [
            String(sqlite3_column_int64(statement, 0)),
            String(sqlite3_column_int64(statement, 1)),
            row.mainChainID.map(String.init) ?? "-",
            String(row.hidden),
            row.title ?? ""
        ].joined(separator: "\u{1F}")
        let seconds = min(max(row.lastActivityAt ?? 0, 0), Int64.max / 1_000_000_000)
        return SessionChangeFingerprint(
            mtimeNanos: seconds * 1_000_000_000,
            size: Int64(bitPattern: fnv1a64(marker))
        )
    }

    /// FNV-1a, 64-bit. Deterministic across launches, which `Hasher` is not,
    /// and the fingerprint is persisted.
    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let (database, sessionID) = Self.locate(fileURL) else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): not a Devin session locator")
        }
        guard Self.isRegularFile(database) else {
            throw SessionParseError.unreadable(database.lastPathComponent)
        }
        let read = LiveSQLiteReader.read(at: database) { handle -> Head? in
            guard let row = try Self.sessionRow(handle, sessionID: sessionID) else { return nil }
            guard !row.isHidden else {
                return Head(row: row, firstPrompt: nil, lastReply: nil, lastModel: nil, messageBytes: 0)
            }
            return try Self.head(handle, row: row)
        }
        guard let read else { throw SessionParseError.unreadable(database.lastPathComponent) }
        guard let head = read else {
            throw SessionParseError.invalidFormat("\(database.lastPathComponent): no such session")
        }
        guard !head.row.isHidden else {
            // Devin's own helper agents persist these; Devin lists none of them.
            throw SessionParseError.invalidFormat("\(database.lastPathComponent): hidden session")
        }

        return SessionSummary(
            provider: .devin,
            sessionID: sessionID,
            harness: .devin,
            model: head.lastModel ?? SessionParsing.string(head.row.model),
            title: SessionParsing.display(head.row.title ?? head.firstPrompt, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(head.lastReply, limit: SessionParsing.summaryLimit),
            projectDir: SessionParsing.string(head.row.workingDirectory),
            createdAt: head.row.createdAt.flatMap { SessionParsing.date(NSNumber(value: $0)) },
            lastActiveAt: head.row.lastActivityAt.flatMap { SessionParsing.date(NSNumber(value: $0)) },
            sourcePath: fileURL.path,
            sizeBytes: head.messageBytes
        )
    }

    struct Head {
        let row: SessionRow
        let firstPrompt: String?
        let lastReply: String?
        let lastModel: String?
        let messageBytes: Int64
    }

    /// The list-row facts, reading only a bounded window at each end of the
    /// main chain.
    static func head(_ handle: OpaquePointer, row: SessionRow) throws -> Head {
        let chain = try mainChain(handle, sessionID: row.id, tip: row.mainChainID)
        let lookup = try NodeLookup(handle, sessionID: row.id)

        var firstPrompt: String?
        if row.title == nil {
            for nodeID in chain.nodes.prefix(headScanNodes) {
                guard let node = try lookup.node(nodeID), node.role == "user", !node.isInjected else { continue }
                if let text = SessionParsing.string(SessionParsing.extractText(node.message["content"])) {
                    firstPrompt = text
                    break
                }
            }
        }

        var lastReply: String?
        var lastModel: String?
        for nodeID in chain.nodes.suffix(tailScanNodes).reversed() {
            guard let node = try lookup.node(nodeID), node.role == "assistant" else { continue }
            if lastModel == nil { lastModel = node.generationModel }
            if lastReply == nil {
                lastReply = SessionParsing.string(SessionParsing.extractText(node.message["content"]))
            }
            if lastModel != nil, lastReply != nil { break }
        }

        return Head(
            row: row,
            firstPrompt: firstPrompt,
            lastReply: lastReply,
            lastModel: lastModel,
            messageBytes: messageBytes(handle, sessionID: row.id)
        )
    }

    /// Bytes this session's messages occupy in the shared store — the
    /// closest honest answer to "how big is this session". `octet_length`
    /// reads the record header rather than the text; a SQLite too old to have
    /// it answers 0 instead of failing the row.
    static func messageBytes(_ handle: OpaquePointer, sessionID: String) -> Int64 {
        guard let statement = try? LiveSQLiteReader.prepare(
            handle,
            "SELECT COALESCE(SUM(octet_length(chat_message)), 0) FROM message_nodes WHERE session_id = ?1"
        ) else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return max(0, sqlite3_column_int64(statement, 0))
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        guard let (database, sessionID) = Self.locate(fileURL) else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): not a Devin session locator")
        }
        guard Self.isRegularFile(database) else {
            throw SessionParseError.unreadable(database.lastPathComponent)
        }
        let read = LiveSQLiteReader.read(at: database) { handle -> (messages: [SessionMessage], cut: Bool)? in
            guard let row = try Self.sessionRow(handle, sessionID: sessionID) else { return nil }
            return try Self.transcript(handle, row: row)
        }
        guard let read else { throw SessionParseError.unreadable(database.lastPathComponent) }
        guard let (messages, cut) = read else {
            throw SessionParseError.invalidFormat("\(database.lastPathComponent): no such session")
        }
        let document = SessionTranscriptSlicing.document(messages: messages, range: range)
        guard cut else { return document }
        return TranscriptDocument(
            messages: document.messages,
            totalMessageCount: document.totalMessageCount,
            truncated: true
        )
    }

    /// The main chain, root first, as transcript messages.
    ///
    /// - `system` nodes (the system prompt, rules, skill lists, environment
    ///   blocks) are the harness talking to the model and are dropped;
    /// - a `user` node whose `metadata.is_user_input` is explicitly `false`
    ///   was injected by Devin rather than typed, and is dropped;
    /// - an `assistant` node yields its prose and then one `[Tool: name]`
    ///   message per tool call; `thinking` is dropped, as every adapter drops
    ///   a model's private reasoning;
    /// - a `tool` node yields its result text.
    static func transcript(_ handle: OpaquePointer, row: SessionRow) throws -> (messages: [SessionMessage], cut: Bool) {
        let chain = try mainChain(handle, sessionID: row.id, tip: row.mainChainID)
        let lookup = try NodeLookup(handle, sessionID: row.id)

        var messages: [SessionMessage] = []
        func append(_ role: SessionRole, _ text: String, _ timestamp: Date?) {
            guard !text.isEmpty else { return }
            messages.append(SessionMessage(seq: messages.count, role: role, text: text, timestamp: timestamp))
        }

        var budget = maxTranscriptBytes
        var cut = chain.truncated
        for nodeID in chain.nodes {
            guard budget > 0 else {
                cut = true
                break
            }
            guard let node = try lookup.node(nodeID) else { continue }
            budget -= node.byteCount
            let timestamp = node.timestamp
            switch node.role {
            case "user":
                guard !node.isInjected else { continue }
                append(.user, SessionParsing.extractText(node.message["content"]), timestamp)
            case "assistant":
                append(.assistant, SessionParsing.extractText(node.message["content"]), timestamp)
                for call in (node.message["tool_calls"] as? [[String: Any]]) ?? [] {
                    append(.tool, toolCallText(call), timestamp)
                }
            case "tool":
                append(.tool, SessionParsing.extractText(node.message["content"]), timestamp)
            default:
                continue
            }
        }
        return (messages, cut)
    }

    /// `[Tool: name]` plus its arguments. The call's own `name` / `arguments`
    /// are read first, then an OpenAI-style `function` object, so either
    /// spelling renders.
    static func toolCallText(_ call: [String: Any]) -> String {
        let function = call["function"] as? [String: Any]
        let name = SessionParsing.firstString(
            call["name"], function?["name"], call["inference_tool_name"], call["tool_name"]
        ) ?? "tool"
        let rawArguments = call["arguments"] ?? function?["arguments"] ?? call["input"]
        let arguments: String?
        if let text = rawArguments as? String {
            arguments = SessionParsing.string(text)
        } else if let rawArguments,
                  JSONSerialization.isValidJSONObject(rawArguments),
                  let data = try? JSONSerialization.data(withJSONObject: rawArguments, options: [.sortedKeys]) {
            arguments = SessionParsing.truncate(String(decoding: data, as: UTF8.self), limit: 4_000)
        } else {
            arguments = nil
        }
        return arguments.map { "[Tool: \(name)]\n\($0)" } ?? "[Tool: \(name)]"
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.devin)
    }

    // MARK: - Rows

    struct SessionRow {
        let id: String
        let workingDirectory: String?
        let model: String?
        let createdAt: Int64?
        let lastActivityAt: Int64?
        let title: String?
        let mainChainID: Int64?
        let hidden: Int64

        var isHidden: Bool { hidden != 0 }
    }

    /// Visible sessions, most recently active first. A database from before
    /// Devin added the `hidden` column has nothing hidden in it.
    static func visibleSessionIDs(_ handle: OpaquePointer) throws -> [String] {
        let statement: OpaquePointer
        if let filtered = try? LiveSQLiteReader.prepare(
            handle,
            "SELECT id FROM sessions WHERE hidden = 0 ORDER BY last_activity_at DESC, id LIMIT ?1"
        ) {
            statement = filtered
        } else {
            statement = try LiveSQLiteReader.prepare(
                handle,
                "SELECT id FROM sessions ORDER BY last_activity_at DESC, id LIMIT ?1"
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(maxSessions))
        var ids: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let id = LiveSQLiteReader.text(statement, 0) { ids.append(id) }
            case SQLITE_DONE:
                return ids
            default:
                throw LiveSQLiteReader.ReadError.statement
            }
        }
    }

    static func sessionRow(_ handle: OpaquePointer, sessionID: String) throws -> SessionRow? {
        let columns = "id, working_directory, model, created_at, last_activity_at, title, main_chain_id"
        let statement: OpaquePointer
        let hasHidden: Bool
        if let withHidden = try? LiveSQLiteReader.prepare(
            handle, "SELECT \(columns), hidden FROM sessions WHERE id = ?1"
        ) {
            statement = withHidden
            hasHidden = true
        } else {
            statement = try LiveSQLiteReader.prepare(handle, "SELECT \(columns) FROM sessions WHERE id = ?1")
            hasHidden = false
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sessionID)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return SessionRow(
                id: LiveSQLiteReader.text(statement, 0) ?? sessionID,
                workingDirectory: LiveSQLiteReader.text(statement, 1),
                model: LiveSQLiteReader.text(statement, 2),
                createdAt: int64(statement, 3),
                lastActivityAt: int64(statement, 4),
                title: SessionParsing.string(LiveSQLiteReader.text(statement, 5)),
                mainChainID: int64(statement, 6),
                hidden: hasHidden ? (int64(statement, 7) ?? 0) : 0
            )
        case SQLITE_DONE:
            return nil
        default:
            throw LiveSQLiteReader.ReadError.statement
        }
    }

    // MARK: - The main chain

    struct Chain {
        /// Root first.
        let nodes: [Int64]
        /// The walk stopped at `maxChainNodes` before reaching a root.
        let truncated: Bool
    }

    /// Node ids from the chain's root to `tip`, following `parent_node_id`.
    ///
    /// `tip` is `sessions.main_chain_id`. When that is missing or names a node
    /// the session does not hold, the newest node stands in — the same
    /// `MAX(node_id)` Devin itself reads. A parent the session does not hold
    /// ends the walk as a root would, and a node seen twice (a cycle, which a
    /// well-formed forest never has) ends it too.
    static func mainChain(_ handle: OpaquePointer, sessionID: String, tip: Int64?) throws -> Chain {
        let statement = try LiveSQLiteReader.prepare(
            handle,
            "SELECT parent_node_id FROM message_nodes WHERE session_id = ?1 AND node_id = ?2"
        )
        defer { sqlite3_finalize(statement) }

        func walk(from start: Int64) throws -> Chain {
            var ids: [Int64] = []
            var seen: Set<Int64> = []
            var current: Int64? = start
            while let id = current {
                guard ids.count < maxChainNodes else {
                    return Chain(nodes: ids.reversed(), truncated: true)
                }
                guard seen.insert(id).inserted else { break }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, sessionID)
                sqlite3_bind_int64(statement, 2, id)
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    ids.append(id)
                    current = int64(statement, 0)
                case SQLITE_DONE:
                    current = nil
                default:
                    throw LiveSQLiteReader.ReadError.statement
                }
            }
            return Chain(nodes: ids.reversed(), truncated: false)
        }

        if let tip {
            let chain = try walk(from: tip)
            if !chain.nodes.isEmpty { return chain }
        }
        guard let newest = try newestNodeID(handle, sessionID: sessionID) else {
            return Chain(nodes: [], truncated: false)
        }
        return try walk(from: newest)
    }

    static func newestNodeID(_ handle: OpaquePointer, sessionID: String) throws -> Int64? {
        let statement = try LiveSQLiteReader.prepare(
            handle, "SELECT MAX(node_id) FROM message_nodes WHERE session_id = ?1"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw LiveSQLiteReader.ReadError.statement }
        return int64(statement, 0)
    }

    // MARK: - Nodes

    struct Node {
        let message: [String: Any]
        let byteCount: Int
        let createdAt: Int64?

        var role: String? { message["role"] as? String }

        var metadata: [String: Any]? { message["metadata"] as? [String: Any] }

        /// Devin marks a prompt a person typed `is_user_input: true`; a user
        /// turn that says `false` was put there by the harness.
        var isInjected: Bool {
            guard let flag = metadata?["is_user_input"] as? NSNumber else { return false }
            return !flag.boolValue
        }

        var generationModel: String? { SessionParsing.string(metadata?["generation_model"]) }

        /// The message's own ISO stamp, which survives compaction; the row's
        /// `created_at` is when the node was (re)written.
        var timestamp: Date? {
            SessionParsing.date(metadata?["created_at"])
                ?? createdAt.flatMap { SessionParsing.date(NSNumber(value: $0)) }
        }
    }

    /// One prepared point lookup, reused for every node of a walk.
    final class NodeLookup {
        private let statement: OpaquePointer
        private let sessionID: String

        init(_ handle: OpaquePointer, sessionID: String) throws {
            self.statement = try LiveSQLiteReader.prepare(
                handle,
                "SELECT chat_message, created_at FROM message_nodes WHERE session_id = ?1 AND node_id = ?2"
            )
            self.sessionID = sessionID
        }

        deinit { sqlite3_finalize(statement) }

        /// `nil` for a node that is gone or whose message is not a JSON
        /// object; a step error throws so the read is retried whole.
        func node(_ nodeID: Int64) throws -> Node? {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            DevinSessionAdapter.bind(statement, 1, sessionID)
            sqlite3_bind_int64(statement, 2, nodeID)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let raw = sqlite3_column_text(statement, 0) else { return nil }
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard length > 0, length <= LiveSQLiteReader.maxBlobBytes else { return nil }
                let data = Data(bytes: raw, count: length)
                guard let message = SessionParsing.json(data) else { return nil }
                return Node(
                    message: message,
                    byteCount: length,
                    createdAt: DevinSessionAdapter.int64(statement, 1)
                )
            case SQLITE_DONE:
                return nil
            default:
                throw LiveSQLiteReader.ReadError.statement
            }
        }
    }

    // MARK: - Column helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    static func int64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_int64(statement, column)
        case SQLITE_TEXT: return LiveSQLiteReader.text(statement, column).flatMap { Int64($0) }
        default: return nil
        }
    }
}
