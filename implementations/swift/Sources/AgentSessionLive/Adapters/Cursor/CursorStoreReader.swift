import AgentSessionKit
import Foundation
import SQLite3

/// Read-only access to one Cursor `store.db`, and the incremental walk of its
/// blob graph.
///
/// ## The store
///
/// Two tables, no published schema:
///
/// - `meta(key TEXT PRIMARY KEY, value TEXT)` — row `'0'` holds the
///   conversation card as hex-encoded JSON. See ``CursorStoreMeta``.
/// - `blobs(id TEXT PRIMARY KEY, data BLOB)` — content-addressed by the
///   SHA-256 of the value, so a blob is immutable: once written it can never
///   change, move, or be renumbered.
///
/// A blob is one of two things. A **message** starts with `{` and is JSON with
/// a `role`. A **node** is protobuf with no schema, whose length-32
/// length-delimited fields are references to other blobs and whose field 4,
/// when present, is a message inlined instead of referenced.
///
/// ## The graph, and why the walk can be incremental
///
/// `latestRootBlobId` names the head. From it, breadth-first over every
/// 32-byte reference reaches the whole conversation, and discovery order *is*
/// conversation order — a node lists its message references in turn order.
///
/// Each turn writes a new head. Because the graph is content-addressed, every
/// blob the previous head reached keeps the id it had, so passing the previous
/// walk's `visited` set as `seen` means the next walk fetches only what is
/// genuinely new. That holds whichever shape the head takes — a node that
/// re-lists every message, or one that chains to its predecessor — because
/// both are "reachable ids, minus the ones already reached".
///
/// ## Two phases, on purpose
///
/// ``walk(from:seen:)`` answers *where the messages are*: it fetches blobs and
/// classifies them by their first byte, but parses no JSON.
/// ``decode(_:)`` answers *what they say*, for the handful a caller actually
/// needs — the ones past a persisted anchor, or the tail of a cold start.
/// Splitting them is what keeps a restart from re-parsing a conversation it
/// only needs to find its place in.
///
/// ## Locking
///
/// Every read goes through `AgentSessionKit`'s `LiveSQLiteReader`, which opens
/// `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` with a 250 ms busy timeout and
/// falls back to a private snapshot copy when Cursor's own handle will not let
/// go. Nothing here ever takes a write lock, and `immutable=1` is never used
/// on the original: the store has a live WAL, and telling SQLite there is no
/// journal to replay is how a torn read happens.
public struct CursorStoreReader: Sendable {
    /// The `store.db` this reader is about.
    public let path: String

    /// Blobs fetched in one walk. A conversation past this is truncated
    /// rather than followed: the graph is another app's, and a poll must not
    /// be able to cost an unbounded number of point lookups.
    public static let maxBlobsVisited = 4_000
    /// Bytes fetched in one walk, across every blob.
    public static let maxBytesVisited = 16 * 1024 * 1024
    /// `meta` rows examined while looking for the conversation card.
    public static let maxMetaRows = 16
    /// Messages decoded in one `decode` call.
    public static let maxMessagesDecoded = 2_000

    /// Creates a reader over a store path. Opens nothing until it is asked a
    /// question.
    public init(path: String) {
        self.path = path
    }

    private var url: URL { URL(fileURLWithPath: path) }

    // MARK: - The card

    /// The conversation card, or `nil` when the store could not be read or
    /// holds no row that decodes to one.
    ///
    /// Cursor writes it under key `'0'`, but the rows are read in key order
    /// rather than fetched by key: they are tiny, and a store whose card moved
    /// should keep listing rather than vanish.
    public func readMeta() -> CursorStoreMeta? {
        LiveSQLiteReader.read(at: url) { database -> CursorStoreMeta? in
            let statement = try LiveSQLiteReader.prepare(database, "SELECT value FROM meta ORDER BY key")
            defer { sqlite3_finalize(statement) }
            var rows = 0
            while sqlite3_step(statement) == SQLITE_ROW, rows < Self.maxMetaRows {
                rows += 1
                guard let hex = LiveSQLiteReader.text(statement, 0),
                      let data = CursorHex.decode(hex),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let card = CursorStoreMeta.decode(json: object)
                else { continue }
                return card
            }
            return nil
        } ?? nil
    }

    /// One blob by id, or `nil` when the store does not hold it.
    public func blob(id: String) -> Data? {
        LiveSQLiteReader.read(at: url) { database -> Data? in
            let statement = try LiveSQLiteReader.prepare(database, Self.blobSQL)
            defer { sqlite3_finalize(statement) }
            return try Self.blob(statement, id: id)
        } ?? nil
    }

    // MARK: - The walk

    /// What one traversal found.
    public struct Walk: Hashable, Sendable {
        /// Every message reachable from the root and not already `seen`, in
        /// conversation order. References only — call ``CursorStoreReader/decode(_:)``
        /// for the content.
        public let messages: [CursorMessageRef]
        /// Every blob id fetched during the walk, nodes included. A caller
        /// unions this into its own `seen` set so the next walk skips it.
        public let visited: [String]
        /// `true` when a limit stopped the walk before the graph ran out.
        public let truncated: Bool

        /// Creates a result.
        public init(messages: [CursorMessageRef], visited: [String], truncated: Bool) {
            self.messages = messages
            self.visited = visited
            self.truncated = truncated
        }
    }

    /// Breadth-first from `root`, skipping anything in `seen`.
    ///
    /// Skipping a seen id also skips its subtree, which is correct exactly
    /// because `seen` came from a previous *complete* walk: everything that
    /// blob referenced was enqueued then. A partial `seen` — one a caller
    /// assembled by hand — would lose messages, so the only sets passed here
    /// are ones this method produced.
    ///
    /// A reference the store does not hold is skipped rather than treated as
    /// corruption, and a node that points back at an ancestor is visited once:
    /// the graph is a merkle chain and back-edges are normal.
    public func walk(from root: String, seen: Set<String> = []) -> Walk {
        guard !root.isEmpty, !seen.contains(root) else {
            return Walk(messages: [], visited: [], truncated: false)
        }
        let result = LiveSQLiteReader.read(at: url) { database -> Walk in
            let statement = try LiveSQLiteReader.prepare(database, Self.blobSQL)
            defer { sqlite3_finalize(statement) }

            var queue = [root]
            var enqueued: Set<String> = seen.union([root])
            var visited: [String] = []
            var messages: [CursorMessageRef] = []
            var budget = Self.maxBytesVisited
            var index = 0
            var truncated = false

            while index < queue.count {
                guard visited.count < Self.maxBlobsVisited, budget > 0 else {
                    truncated = true
                    break
                }
                let id = queue[index]
                index += 1
                guard let data = try Self.blob(statement, id: id) else { continue }
                visited.append(id)
                budget -= data.count

                if Self.looksLikeMessage(data) {
                    messages.append(CursorMessageRef(blobID: id))
                    continue
                }

                var inlineIndex = 0
                for field in ProtobufWireReader.fields(in: [UInt8](data)) {
                    if field.number == Self.inlineMessageField,
                       let bytes = field.bytes,
                       Self.looksLikeMessage(bytes) {
                        messages.append(CursorMessageRef(blobID: id, partIndex: inlineIndex))
                        inlineIndex += 1
                    }
                    guard let bytes = field.bytes, bytes.count == Self.referenceByteCount else {
                        continue
                    }
                    let reference = CursorHex.encode(bytes)
                    if enqueued.insert(reference).inserted { queue.append(reference) }
                }
            }
            return Walk(messages: messages, visited: visited, truncated: truncated)
        }
        return result ?? Walk(messages: [], visited: [], truncated: false)
    }

    /// Parses the messages `refs` point at, in the order given.
    ///
    /// One point lookup per distinct blob, so a caller that asks for a
    /// contiguous tail pays for exactly those blobs. A ref the store no longer
    /// holds, or one whose blob turned out not to carry a message at that
    /// index, is dropped — parsing is total here for the same reason it is in
    /// `AgentSessionKit`: one bad record must not sink a poll.
    public func decode(_ refs: [CursorMessageRef]) -> [CursorMessage] {
        guard !refs.isEmpty else { return [] }
        let wanted = Array(refs.prefix(Self.maxMessagesDecoded))
        let result = LiveSQLiteReader.read(at: url) { database -> [CursorMessage] in
            let statement = try LiveSQLiteReader.prepare(database, Self.blobSQL)
            defer { sqlite3_finalize(statement) }

            var cache: [String: Data] = [:]
            var out: [CursorMessage] = []
            for ref in wanted {
                let data: Data?
                if let hit = cache[ref.blobID] {
                    data = hit
                } else {
                    data = try Self.blob(statement, id: ref.blobID)
                    if let data { cache[ref.blobID] = data }
                }
                guard let data, let message = Self.message(in: data, ref: ref) else { continue }
                out.append(message)
            }
            return out
        }
        return result ?? []
    }

    // MARK: - Blob shapes

    /// Field 4 of a node is a message inlined rather than referenced.
    /// Observed on Cursor 2026 stores; there is no public schema, so an
    /// unrecognised field is ignored rather than guessed at.
    static let inlineMessageField = 4
    /// Blob ids are SHA-256, so a reference is exactly 32 bytes.
    static let referenceByteCount = 32

    private static let blobSQL = "SELECT data FROM blobs WHERE id = ?"

    /// Cheap classification: one byte.
    ///
    /// A message is JSON and opens with `{`; a node is protobuf and opens with
    /// a wire key, and `0x7B` as a key would be field 15 wire type 3 — a
    /// proto2 group, which nothing here emits and which
    /// ``ProtobufWireReader`` refuses anyway. So the brace is the whole test.
    ///
    /// It is deliberately *not* also a scan for `"role"`. Key order in the
    /// stored JSON is not ours to choose, and a message whose `content` runs
    /// to a hundred kilobytes puts its `role` past any bounded window — which
    /// would classify the longest messages in a conversation as nodes and drop
    /// them. The role check belongs where the JSON is being parsed anyway:
    /// ``message(in:ref:)`` returns `nil` for a JSON blob that has none, and
    /// ``decode(_:)`` drops it.
    static func looksLikeMessage(_ bytes: some Collection<UInt8>) -> Bool {
        bytes.first == UInt8(ascii: "{")
    }

    /// The message at `ref` inside a blob's bytes.
    static func message(in data: Data, ref: CursorMessageRef) -> CursorMessage? {
        if looksLikeMessage(data) {
            guard ref.partIndex == 0,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return CursorMessage.decode(object, ref: ref)
        }
        var inlineIndex = 0
        for field in ProtobufWireReader.fields(in: [UInt8](data)) {
            guard field.number == inlineMessageField,
                  let bytes = field.bytes,
                  looksLikeMessage(bytes)
            else { continue }
            defer { inlineIndex += 1 }
            guard inlineIndex == ref.partIndex else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
            else { return nil }
            return CursorMessage.decode(object, ref: ref)
        }
        return nil
    }

    /// `nil` only for a genuinely missing row. A step error (`SQLITE_BUSY`,
    /// `SQLITE_LOCKED`, …) on Cursor's live handle throws so
    /// `LiveSQLiteReader.read` abandons the pass and retries on a snapshot
    /// rather than reporting a silently partial walk.
    private static func blob(_ statement: OpaquePointer, id: String) throws -> Data? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        // `SQLITE_TRANSIENT`: SQLite copies the id before returning, which is
        // what lets `id` be a Swift string with a lifetime of this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return LiveSQLiteReader.blob(statement, 0)
        case SQLITE_DONE: return nil
        default: throw LiveSQLiteReader.ReadError.statement
        }
    }
}
