import AgentSessionKit
import Foundation

/// One decoded JSON value out of a Grok Build record.
///
/// Same shape and the same reasons as ``CodexJSON``: a lenient, `Sendable`
/// value tree, read once per line and queried by key, because the records are
/// heterogeneous and grow fields between releases. A `tool_call` update carries
/// `kind` and `status` for a built-in tool and neither for a backend one; a
/// `tool_call_update` carries `rawOutput` as `{error, message}` when it failed
/// and as a nested `{action: {query, sources: […]}}` when it did not; `content`
/// is a bare string on a `chat_history` assistant record and an array of typed
/// blocks on a user one. A `Codable` model would need a vintage per release,
/// and a live board that goes blank on a `grok` point release is worse than one
/// that ignores a record it does not recognise.
///
/// Deliberately *not* ``CodexJSON`` itself. That type is documented entirely in
/// terms of Codex rollouts and is public API; hoisting a shared lenient tree out
/// of both adapters is a worthwhile change, but it is a change to the module's
/// own vocabulary and belongs in its own commit rather than riding along with a
/// new harness.
public enum GrokJSON: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GrokJSON])
    case object([String: GrokJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GrokJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: GrokJSON].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    /// Parses a whole JSON document, or `nil` when it is not JSON at all.
    public static func decode(_ data: Data) -> GrokJSON? {
        try? JSONDecoder().decode(GrokJSON.self, from: data)
    }

    /// Parses a JSON document from a file, bounded by `maxBytes`.
    ///
    /// The snapshot files this reads — `summary.json`, `signals.json`,
    /// `active_sessions.json` — are a few kilobytes each, and a cap keeps a
    /// truncated or maliciously large file from being pulled into memory during
    /// discovery.
    static func decode(contentsOf url: URL, maxBytes: Int = 1 << 20) -> GrokJSON? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        return decode(data)
    }

    /// A member of an object, or `nil` for every other case. A JSON `null`
    /// answers `nil` too — an explicitly null field is an absent one.
    public subscript(key: String) -> GrokJSON? {
        guard case let .object(members) = self else { return nil }
        let value = members[key]
        if case .null = value { return nil }
        return value
    }

    /// The string value, or `nil` when this is not a string. Strict: a number
    /// spelled like an id is still not a string.
    public var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The value as an integer, accepting a numeric string as well.
    public var int: Int? {
        switch self {
        case let .number(value):
            guard value.isFinite else { return nil }
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    /// The value as a `Double`, accepting a numeric string as well.
    public var double: Double? {
        switch self {
        case let .number(value):
            return value.isFinite ? value : nil
        case let .string(value):
            return Double(value)
        default:
            return nil
        }
    }

    /// The boolean value, or `nil` when this is not a boolean.
    public var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// The elements, or `nil` when this is not an array.
    public var array: [GrokJSON]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    /// The members, or `nil` when this is not an object.
    public var object: [String: GrokJSON]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    /// The first non-empty string among `keys`, in the order given.
    public func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    /// Every piece of prose found by walking this value, in order.
    ///
    /// Handles the shapes a Grok payload uses for text without the caller
    /// having to know which one it is looking at: a bare string, a
    /// `{"type": "text", "text": …}` block, the
    /// `{"type": "content", "content": {…}}` wrapper a failed
    /// `tool_call_update` puts around one, a `{"summary": [{"text": …}]}`
    /// reasoning record, and arrays of any of those. Recursion is bounded by
    /// `depth`, so a pathological record cannot blow the stack.
    public func texts(depth: Int = 8) -> [String] {
        guard depth > 0 else { return [] }
        switch self {
        case let .string(value):
            return value.isEmpty ? [] : [value]
        case let .array(elements):
            return elements.flatMap { $0.texts(depth: depth - 1) }
        case let .object(members):
            if let text = members["text"]?.string {
                return text.isEmpty ? [] : [text]
            }
            for key in ["content", "summary", "message", "error"] {
                guard let nested = members[key] else { continue }
                let found = nested.texts(depth: depth - 1)
                if !found.isEmpty { return found }
            }
            return []
        case .null, .bool, .number:
            return []
        }
    }

    /// The concatenation of ``texts(depth:)``, newline-separated.
    public var joinedText: String { texts().joined(separator: "\n") }
}

// MARK: - Line records

/// Which of a session's three tailable files a line came from.
///
/// The mapper is stateless and sees one line at a time, so the file is what
/// tells it which vocabulary to read the line in. The three overlap — a tool
/// call appears in all of them, in three different shapes — and picking one
/// source per fact is what keeps the same call from being counted three times.
/// See ``GrokRecordMapper`` for that table.
public enum GrokSourceFile: String, Sendable, Hashable, CaseIterable {
    /// `events.jsonl` — the harness's own lifecycle log.
    case events
    /// `updates.jsonl` — the ACP-shaped stream the UI renders from.
    case updates
    /// `chat_history.jsonl` — the model-facing conversation.
    case chatHistory

    /// The file's name inside a session directory.
    public var fileName: String {
        switch self {
        case .events: "events.jsonl"
        case .updates: "updates.jsonl"
        case .chatHistory: "chat_history.jsonl"
        }
    }
}

/// One line of `events.jsonl`: `{"ts": <ISO-8601>, "type": …, …}`.
///
/// Flat — everything but `ts` and `type` is a sibling field, not a nested
/// payload — so ``fields`` is the whole envelope and a lookup like
/// `fields["tool_name"]` reads the record directly.
public struct GrokEventRecord: Sendable, Hashable {
    /// The source's own timestamp, or `nil` when the line carried none.
    public let timestamp: Date?
    /// The discriminator: `turn_started`, `phase_changed`, `tool_completed`, …
    public let type: String
    /// The whole line, for reading the type's own fields.
    public let fields: GrokJSON

    /// Creates a record. Used by tests; a tailer goes through ``decode(_:)``.
    public init(timestamp: Date?, type: String, fields: GrokJSON) {
        self.timestamp = timestamp
        self.type = type
        self.fields = fields
    }

    /// Parses one line, or returns `nil` when it is not an event record.
    public static func decode(_ data: Data) -> GrokEventRecord? {
        guard let root = GrokJSON.decode(data), let type = root["type"]?.string else { return nil }
        return GrokEventRecord(
            timestamp: root["ts"]?.string.flatMap(SessionParsing.parseISO),
            type: type,
            fields: root
        )
    }
}

/// One line of `updates.jsonl`: a JSON-RPC notification wrapping one
/// `sessionUpdate`.
///
/// ```json
/// {"timestamp": 1787083805, "method": "_x.ai/session/update",
///  "params": {"sessionId": "…", "update": {"sessionUpdate": "tool_call", …},
///             "_meta": {"eventId": "…", "agentTimestampMs": 1787083805389}}}
/// ```
///
/// The outer `timestamp` is whole seconds; `_meta.agentTimestampMs` is the same
/// instant in milliseconds and is preferred when present, because a whole
/// turn's updates otherwise collapse onto one second and the fan-out tailer
/// merges by timestamp.
public struct GrokUpdateRecord: Sendable, Hashable {
    /// The source's own timestamp, or `nil` when the line carried none.
    public let timestamp: Date?
    /// The session the line belongs to, as the record itself spells it.
    public let sessionID: String?
    /// The update's discriminator: `tool_call`, `agent_message_chunk`, …
    public let updateType: String
    /// The `params.update` object.
    public let update: GrokJSON
    /// The `params._meta` object.
    public let meta: GrokJSON?

    /// Creates a record. Used by tests; a tailer goes through ``decode(_:)``.
    public init(
        timestamp: Date?,
        sessionID: String?,
        updateType: String,
        update: GrokJSON,
        meta: GrokJSON? = nil
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.updateType = updateType
        self.update = update
        self.meta = meta
    }

    /// Parses one line, or returns `nil` when it is not an update record.
    public static func decode(_ data: Data) -> GrokUpdateRecord? {
        guard let root = GrokJSON.decode(data),
              let params = root["params"],
              let update = params["update"],
              let type = update["sessionUpdate"]?.string
        else { return nil }
        let meta = params["_meta"]
        return GrokUpdateRecord(
            timestamp: Self.instant(root: root, meta: meta),
            sessionID: params["sessionId"]?.string,
            updateType: type,
            update: update,
            meta: meta
        )
    }

    /// Milliseconds when the record offers them, whole seconds otherwise.
    private static func instant(root: GrokJSON, meta: GrokJSON?) -> Date? {
        if let millis = meta?["agentTimestampMs"]?.double, millis > 0 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        if let seconds = root["timestamp"]?.double, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// One line of `chat_history.jsonl`: the conversation as the model sees it.
///
/// Carries no timestamp of its own — the file is the message list, not a log —
/// so ``GrokRecordMapper`` stamps these with the observation clock. That is why
/// turn boundaries come from `events.jsonl` and not from here: a fan-out tailer
/// that merged undated records by timestamp would sort a whole turn's prose to
/// the moment it happened to be read.
public struct GrokChatRecord: Sendable, Hashable {
    /// `user`, `assistant`, `reasoning`, `backend_tool_call`, `tool_result`,
    /// `system`.
    public let type: String
    /// The whole line.
    public let fields: GrokJSON

    /// Creates a record. Used by tests; a tailer goes through ``decode(_:)``.
    public init(type: String, fields: GrokJSON) {
        self.type = type
        self.fields = fields
    }

    /// Parses one line, or returns `nil` when it is not a chat record.
    public static func decode(_ data: Data) -> GrokChatRecord? {
        guard let root = GrokJSON.decode(data), let type = root["type"]?.string else { return nil }
        return GrokChatRecord(type: type, fields: root)
    }
}

// MARK: - Snapshot files

/// `summary.json` — a session's identity, rewritten in place as it changes.
///
/// A snapshot rather than a log: the harness overwrites the whole file, so
/// nothing can be tailed out of it and the adapter reads it once, at discovery,
/// to seed an identity.
public struct GrokSummary: Sendable, Hashable {
    /// `info.id` — the session id, which is also the directory's name.
    public let sessionID: String?
    /// `info.cwd`, when the summary repeats it. The directory name is the
    /// authority; this is the fallback.
    public let cwd: String?
    /// `generated_title`, falling back to `session_summary`.
    public let title: String?
    /// `current_model_id`.
    public let model: String?
    /// `agent_name` — which bundled agent or persona drove the session.
    public let agentName: String?
    /// `sandbox_profile` — `read-only`, `workspace-write`, …
    public let sandboxProfile: String?
    /// `reasoning_effort`.
    public let reasoningEffort: String?
    /// `created_at`.
    public let createdAt: Date?
    /// `last_active_at`, falling back to `updated_at`.
    public let lastActiveAt: Date?

    /// Creates a summary. Used by tests; discovery goes through ``read(path:)``.
    public init(
        sessionID: String?,
        cwd: String? = nil,
        title: String? = nil,
        model: String? = nil,
        agentName: String? = nil,
        sandboxProfile: String? = nil,
        reasoningEffort: String? = nil,
        createdAt: Date? = nil,
        lastActiveAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.model = model
        self.agentName = agentName
        self.sandboxProfile = sandboxProfile
        self.reasoningEffort = reasoningEffort
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    /// Reads and parses `summary.json`, or returns `nil` when it is missing or
    /// unreadable. Never throws: a session whose summary cannot be parsed is
    /// still a session worth tailing.
    public static func read(path: String) -> GrokSummary? {
        guard let root = GrokJSON.decode(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let info = root["info"]
        return GrokSummary(
            sessionID: info?.firstString("id", "session_id") ?? root.firstString("id", "session_id"),
            cwd: info?["cwd"]?.string ?? root["cwd"]?.string,
            title: root.firstString("generated_title", "title", "session_summary"),
            model: root.firstString("current_model_id", "model"),
            agentName: root["agent_name"]?.string,
            sandboxProfile: root["sandbox_profile"]?.string,
            reasoningEffort: root["reasoning_effort"]?.string,
            createdAt: root["created_at"]?.string.flatMap(SessionParsing.parseISO),
            lastActiveAt: root.firstString("last_active_at", "updated_at")
                .flatMap(SessionParsing.parseISO)
        )
    }
}

/// `signals.json` — the counters the harness keeps for its own telemetry.
///
/// Read at discovery for diagnostics only. Nothing here becomes an
/// ``AgentEvent``: every field is a running total, and the reducer's own
/// counters are built from the events it saw, so folding a total in would
/// double what it already counted.
public struct GrokSignals: Sendable, Hashable {
    /// `turnCount`.
    public let turnCount: Int?
    /// `toolCallCount`.
    public let toolCallCount: Int?
    /// `errorCount`.
    public let errorCount: Int?
    /// `toolFailureCount`.
    public let toolFailureCount: Int?
    /// `compactionCount`.
    public let compactionCount: Int?
    /// `contextTokensUsed` — how much of the window the conversation occupies,
    /// which is not the same thing as tokens billed.
    public let contextTokensUsed: Int?
    /// `contextWindowTokens`.
    public let contextWindowTokens: Int?
    /// `primaryModelId`.
    public let primaryModelID: String?

    /// Creates a signals snapshot.
    public init(
        turnCount: Int? = nil,
        toolCallCount: Int? = nil,
        errorCount: Int? = nil,
        toolFailureCount: Int? = nil,
        compactionCount: Int? = nil,
        contextTokensUsed: Int? = nil,
        contextWindowTokens: Int? = nil,
        primaryModelID: String? = nil
    ) {
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.toolFailureCount = toolFailureCount
        self.compactionCount = compactionCount
        self.contextTokensUsed = contextTokensUsed
        self.contextWindowTokens = contextWindowTokens
        self.primaryModelID = primaryModelID
    }

    /// Reads and parses `signals.json`, or returns `nil` when it is missing or
    /// unreadable.
    public static func read(path: String) -> GrokSignals? {
        guard let root = GrokJSON.decode(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return GrokSignals(
            turnCount: root["turnCount"]?.int,
            toolCallCount: root["toolCallCount"]?.int,
            errorCount: root["errorCount"]?.int,
            toolFailureCount: root["toolFailureCount"]?.int,
            compactionCount: root["compactionCount"]?.int,
            contextTokensUsed: root["contextTokensUsed"]?.int,
            contextWindowTokens: root["contextWindowTokens"]?.int,
            primaryModelID: root["primaryModelId"]?.string
        )
    }
}

/// One entry of `~/.grok/active_sessions.json`.
///
/// The registry is a JSON array the harness rewrites under
/// `active_sessions.lock` — `[]` when nothing is running. Its element is the
/// CLI's own `ActiveSession`: `session_id`, `pid`, `cwd`, `opened_at`.
///
/// Parsing is deliberately looser than that shape. The file is the only
/// explicit statement anywhere on disk that a session is running, so a release
/// that renames a field or writes an array of bare id strings must degrade into
/// "this session is listed" rather than into "nothing is running": every string
/// field of an element is searched for the session id, and `pid` is taken only
/// when a field actually says `pid`.
public struct GrokActiveSession: Sendable, Hashable {
    /// The session the entry names, when a field spelled it.
    public let sessionID: String?
    /// The process driving it, when the entry recorded one.
    public let pid: pid_t?
    /// The working directory the entry recorded.
    public let cwd: String?
    /// Every string anywhere in the entry, for the id search described above.
    let strings: [String]

    /// `true` when this entry names `sessionID`, by its own field or by any
    /// string it carries.
    public func names(_ sessionID: String) -> Bool {
        if let own = self.sessionID, own.caseInsensitiveCompare(sessionID) == .orderedSame {
            return true
        }
        return strings.contains { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
    }
}

/// The `~/.grok/active_sessions.json` registry.
public enum GrokActiveSessions {
    /// The registry's path, relative to a home directory.
    public static let relativePath = ".grok/active_sessions.json"

    /// The registry file for a home directory.
    public static func path(home: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent(relativePath).path
    }

    /// Reads the registry. An absent, empty, or unparseable file is an empty
    /// list — the same answer the harness gives itself when it finds one
    /// corrupt.
    public static func read(home: String) -> [GrokActiveSession] {
        guard let root = GrokJSON.decode(contentsOf: URL(fileURLWithPath: path(home: home))),
              let elements = root.array
        else { return [] }
        return elements.map(entry)
    }

    private static func entry(_ value: GrokJSON) -> GrokActiveSession {
        if let text = value.string {
            return GrokActiveSession(sessionID: text, pid: nil, cwd: nil, strings: [text])
        }
        guard let members = value.object else {
            return GrokActiveSession(sessionID: nil, pid: nil, cwd: nil, strings: [])
        }
        let pid = members["pid"]?.int.map { pid_t(truncatingIfNeeded: $0) }
        return GrokActiveSession(
            sessionID: value.firstString("session_id", "sessionId", "id"),
            pid: pid.flatMap { $0 > 0 ? $0 : nil },
            cwd: value.firstString("cwd", "workspace_root"),
            strings: members.values.compactMap(\.string)
        )
    }
}
