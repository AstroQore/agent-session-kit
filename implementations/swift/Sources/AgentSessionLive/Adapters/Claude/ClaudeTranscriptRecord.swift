import Foundation

/// One block inside a Claude Code `message.content` array.
///
/// `content` is a string on the records a person typed and an array of blocks
/// on everything else, so a parser that assumes either shape drops half the
/// transcript. ``ClaudeTranscriptRecord`` normalises both into this list, and
/// a bare string becomes a single ``text(_:)``.
///
/// Only the block kinds that carry an event are modelled. `image` blocks and
/// anything a future release adds collapse into ``other(type:)`` rather than
/// failing the line: a transcript written by a newer Claude Code than the one
/// this package was built against must still tail.
public enum ClaudeContentBlock: Hashable, Sendable {
    /// Model prose, or the whole of a string-shaped `content`.
    case text(String)
    /// A reasoning block. The text is kept out of events on purpose — the
    /// event model records only *that* the model reasoned.
    case thinking(String)
    /// A tool invocation. `input` is the whitelisted, truncated subset of the
    /// call's arguments described in ``ClaudeTranscriptRecord/toolInputKeys``.
    case toolUse(id: String, name: String, input: [String: String])
    /// A tool's answer, carried on a `type: "user"` record.
    case toolResult(toolUseID: String, text: String, isError: Bool)
    /// A block kind this package does not act on, kept so counts stay honest.
    case other(type: String)
}

/// The `message.usage` counters on an assistant record.
///
/// Deltas for one billed step, not totals. `cachedTokens` folds the two cache
/// counters together because the distinction between reading a cache entry
/// and creating one is an accounting detail no board renders.
public struct ClaudeUsage: Hashable, Sendable {
    /// Fresh input tokens.
    public let inputTokens: Int
    /// Generated tokens, thinking included.
    public let outputTokens: Int
    /// `cache_read_input_tokens` + `cache_creation_input_tokens`.
    public let cachedTokens: Int

    /// Creates a usage record.
    public init(inputTokens: Int, outputTokens: Int, cachedTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
    }
}

/// The `worktreeSession` payload of a `worktree-state` record.
public struct ClaudeWorktreeState: Hashable, Sendable {
    /// Where the session was launched before it entered the worktree.
    public let originalCwd: String?
    /// The worktree the session is operating in now.
    public let worktreePath: String?
    /// The branch checked out inside the worktree.
    public let worktreeBranch: String?

    /// Creates a worktree state.
    public init(originalCwd: String?, worktreePath: String?, worktreeBranch: String?) {
        self.originalCwd = originalCwd
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
    }
}

/// One line of a Claude Code transcript, reduced to the fields this package
/// acts on.
///
/// Deliberately lenient rather than `Decodable`. Three properties of the real
/// format make a synthesised decoder the wrong tool:
///
/// - **`message.content` is a string or an array.** A `Codable` model would
///   need a custom `init(from:)` for that one field anyway.
/// - **Records are heterogeneous.** A `custom-title` line has three keys and
///   an `assistant` line has twenty; a single struct with everything optional
///   decodes both, but only because every field is optional, at which point
///   the compiler is checking nothing.
/// - **Unknown fields must be free.** Claude Code ships weekly and adds record
///   types (`relocated`, `agent-name`, `permission-mode`, `bridge-session`,
///   `frame-link` are all newer than this file). Anything unrecognised must
///   parse into "a record of some type" and be ignored downstream, never
///   throw.
///
/// So the whole line goes through `JSONSerialization` once and the fields
/// worth having are lifted out by name. Everything the type stores is a value,
/// which is what keeps it `Sendable` while the JSON it came from is not.
///
/// ## What "fully stamped" means
///
/// Claude Code writes two shapes of record. Conversation records (`user`,
/// `assistant`, `attachment`, `system`) carry the full envelope —
/// `uuid`, `parentUuid`, `sessionId`, `cwd`, `timestamp`, `gitBranch`,
/// `version`, `isSidechain`, and on subagent lines `agentId`. Auxiliary
/// records (`custom-title`, `last-prompt`, `mode`, `queue-operation`,
/// `worktree-state`) carry `type`, `sessionId`, and their payload, and nothing
/// else — no timestamp, so ``ClaudeRecordMapper`` stamps them with the
/// observation clock. ``isFullyStamped`` is the test, and it is what decides
/// whether a record can seed an identity.
public struct ClaudeTranscriptRecord: Hashable, Sendable {
    /// The record's `type` — `user`, `assistant`, `custom-title`, and so on.
    /// Empty when the line had no `type` at all, which is itself a record
    /// worth skipping rather than an error.
    public let type: String
    /// The `subtype`, which only `system` records carry. `compact_boundary`
    /// is the one that matters.
    public let subtype: String?
    /// The record's own id.
    public let uuid: String?
    /// The record this one answers, threading the conversation.
    public let parentUUID: String?
    /// The session the record belongs to. On a subagent line this is still
    /// the *parent's* session id; ``agentID`` is what separates the child.
    public let sessionID: String?
    /// The subagent this line belongs to, on sidechain records only.
    public let agentID: String?
    /// The working directory at the time the record was written.
    public let cwd: String?
    /// The branch checked out at the time the record was written.
    public let gitBranch: String?
    /// The Claude Code version that wrote the record.
    public let version: String?
    /// Where the session was started from — `claude-desktop`, `cli`, …
    public let entrypoint: String?
    /// `true` on subagent records.
    public let isSidechain: Bool
    /// `true` on injected system context that only *looks* like a prompt —
    /// skill preambles, hook output, command envelopes. Never a person typing.
    public let isMeta: Bool
    /// The source's own timestamp. `nil` on auxiliary records.
    public let timestamp: Date?
    /// The model that produced an assistant record, or `nil` for
    /// `<synthetic>` — Claude Code's own locally generated turns, which no
    /// model ran and which must not become an identity's `model`.
    public let model: String?
    /// `end_turn`, `tool_use`, `stop_sequence`, … on assistant records.
    public let stopReason: String?
    /// Token accounting for the step, on assistant records.
    public let usage: ClaudeUsage?
    /// `message.content`, normalised: a bare string becomes one
    /// ``ClaudeContentBlock/text(_:)``.
    public let content: [ClaudeContentBlock]
    /// Text lifted out of the `toolUseResult` sidecar — `stdout` then
    /// `stderr`, or the whole thing when it is a bare string. Preferred over
    /// the `tool_result` block's own content because it is the unwrapped
    /// output rather than the model-facing rendering of it.
    public let toolResultSidecarText: String?
    /// The pinned title from a `custom-title` record.
    public let customTitle: String?
    /// `enqueue` / `dequeue` / … from a `queue-operation` record.
    public let queueOperation: String?
    /// The queued prompt from a `queue-operation` record.
    public let queueContent: String?
    /// The payload of a `worktree-state` record.
    public let worktree: ClaudeWorktreeState?

    /// `true` when the record carries the full conversation envelope and can
    /// therefore seed a ``SessionIdentity``. See the type's discussion.
    public var isFullyStamped: Bool {
        uuid != nil && sessionID != nil && cwd != nil && timestamp != nil
    }

    /// `true` when every content block is a tool result — the shape of the
    /// `type: "user"` records Claude Code writes for a tool's answer, which
    /// are not a person saying anything.
    public var isToolResultRecord: Bool {
        !content.isEmpty && content.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }

    /// The tool-call arguments worth keeping, and the only ones lifted out of
    /// a `tool_use` block's `input`.
    ///
    /// A whitelist rather than the whole object for two reasons that point the
    /// same way: `Edit` and `Write` inputs carry entire file bodies, so
    /// copying them into a record allocates megabytes per line for a `target`
    /// that is one path; and the fewer transcript bytes that leave the file,
    /// the smaller the surface for the most personal data on the machine to
    /// escape through. Values are truncated at ``toolInputValueLimit``.
    public static let toolInputKeys: Set<String> = [
        "command", "file_path", "path", "notebook_path", "pattern", "glob",
        "query", "url", "description", "subagent_type", "prompt_file"
    ]

    /// Characters kept per whitelisted tool input value.
    public static let toolInputValueLimit = 512

    /// Parses one JSONL line, or returns `nil` when it is not a JSON object.
    ///
    /// Never throws and never rejects a record for having fields it does not
    /// recognise. A line that is not an object at all — a blank, a fragment,
    /// a log message that slipped into the file — yields `nil`, which
    /// ``JSONLTailer`` treats as "no events" and walks past.
    public static func decode(_ data: Data) -> ClaudeTranscriptRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }
        return ClaudeTranscriptRecord(root)
    }

    /// Builds a record from an already-deserialised object.
    public init(_ root: [String: Any]) {
        type = ClaudeJSON.string(root["type"]) ?? ""
        subtype = ClaudeJSON.string(root["subtype"])
        uuid = ClaudeJSON.string(root["uuid"])
        parentUUID = ClaudeJSON.string(root["parentUuid"])
        sessionID = ClaudeJSON.string(root["sessionId"])
        agentID = ClaudeJSON.string(root["agentId"])
        cwd = ClaudeJSON.string(root["cwd"])
        gitBranch = ClaudeJSON.string(root["gitBranch"])
        version = ClaudeJSON.string(root["version"])
        entrypoint = ClaudeJSON.string(root["entrypoint"])
        isSidechain = ClaudeJSON.bool(root["isSidechain"])
        isMeta = ClaudeJSON.bool(root["isMeta"])
        timestamp = ClaudeJSON.date(root["timestamp"])
        customTitle = ClaudeJSON.string(root["customTitle"])
        queueOperation = ClaudeJSON.string(root["operation"])
        queueContent = ClaudeJSON.string(root["content"])

        let message = root["message"] as? [String: Any]
        let rawModel = ClaudeJSON.string(message?["model"])
        model = rawModel == Self.syntheticModel ? nil : rawModel
        stopReason = ClaudeJSON.string(message?["stop_reason"])
        usage = ClaudeJSON.usage(message?["usage"])
        content = ClaudeJSON.blocks(message?["content"])
        toolResultSidecarText = ClaudeJSON.sidecarText(root["toolUseResult"])

        if let session = root["worktreeSession"] as? [String: Any] {
            worktree = ClaudeWorktreeState(
                originalCwd: ClaudeJSON.string(session["originalCwd"]),
                worktreePath: ClaudeJSON.string(session["worktreePath"]),
                worktreeBranch: ClaudeJSON.string(session["worktreeBranch"])
            )
        } else {
            worktree = nil
        }
    }

    /// What Claude Code writes as `message.model` for turns it generated
    /// itself. Not a model anyone ran, so it never reaches an identity.
    public static let syntheticModel = "<synthetic>"
}

/// Field-by-field lifting out of `JSONSerialization` output.
///
/// Every helper answers `nil` rather than throwing, because a transcript line
/// with a field of the wrong type is a line to skip a field of, not a line to
/// abandon.
enum ClaudeJSON {
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func bool(_ value: Any?) -> Bool {
        (value as? Bool) ?? false
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    /// ISO-8601 with fractional seconds, which is what Claude Code writes,
    /// falling back to the plain form for anything that omits them.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let parsed = fractionalISO8601.date(from: text) { return parsed }
        return plainISO8601.date(from: text)
    }

    static func usage(_ value: Any?) -> ClaudeUsage? {
        guard let object = value as? [String: Any] else { return nil }
        let input = int(object["input_tokens"]) ?? 0
        let output = int(object["output_tokens"]) ?? 0
        let cached = (int(object["cache_read_input_tokens"]) ?? 0)
            + (int(object["cache_creation_input_tokens"]) ?? 0)
        guard input != 0 || output != 0 || cached != 0 else { return nil }
        return ClaudeUsage(inputTokens: input, outputTokens: output, cachedTokens: cached)
    }

    /// Normalises `message.content`: a bare string is one text block, an
    /// array is mapped block by block, anything else is empty.
    static func blocks(_ value: Any?) -> [ClaudeContentBlock] {
        if let text = value as? String {
            return text.isEmpty ? [] : [.text(text)]
        }
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let object = element as? [String: Any] else { return nil }
            return block(object)
        }
    }

    private static func block(_ object: [String: Any]) -> ClaudeContentBlock? {
        switch string(object["type"]) {
        case "text":
            guard let text = string(object["text"]) else { return nil }
            return .text(text)
        case "thinking":
            return .thinking(string(object["thinking"]) ?? "")
        case "tool_use":
            guard let id = string(object["id"]), let name = string(object["name"]) else { return nil }
            return .toolUse(id: id, name: name, input: toolInput(object["input"]))
        case "tool_result":
            guard let id = string(object["tool_use_id"]) else { return nil }
            return .toolResult(
                toolUseID: id,
                text: resultText(object["content"]) ?? "",
                isError: bool(object["is_error"])
            )
        case let other?:
            return .other(type: other)
        case nil:
            return nil
        }
    }

    /// The whitelisted, truncated subset of a `tool_use` input. See
    /// ``ClaudeTranscriptRecord/toolInputKeys``.
    private static func toolInput(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var kept: [String: String] = [:]
        for key in ClaudeTranscriptRecord.toolInputKeys {
            guard let text = string(object[key]) else { continue }
            kept[key] = String(text.prefix(ClaudeTranscriptRecord.toolInputValueLimit))
        }
        return kept
    }

    /// A `tool_result` block's own `content`: a string, or an array of text
    /// blocks joined by newlines.
    static func resultText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let array = value as? [Any] else { return nil }
        let parts = array.compactMap { element -> String? in
            guard let object = element as? [String: Any] else { return nil }
            return string(object["text"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Text from the `toolUseResult` sidecar.
    ///
    /// A bare string is the whole answer. An object is `stdout` then `stderr`
    /// — the shape `Bash` writes — and nothing else, because the other sidecar
    /// shapes (`structuredPatch`, `matches`, `task`) are structured data whose
    /// rendering belongs to a host and not to a search index.
    static func sidecarText(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        guard let object = value as? [String: Any] else { return nil }
        let parts = ["stdout", "stderr"].compactMap { string(object[$0]) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // `nonisolated(unsafe)` because `ISO8601DateFormatter` is not `Sendable`
    // even though parsing one is thread-safe: Foundation's date formatters
    // have been safe for concurrent reads since macOS 10.9, and neither of
    // these is mutated after its initialiser returns. The alternative —
    // building a formatter per line — costs more than the JSON parse does.
    nonisolated(unsafe) private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
