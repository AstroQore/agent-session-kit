import AgentSessionKit
import Foundation

/// What a tool call actually does, normalised across harnesses.
///
/// Every harness names its tools differently — `Bash`, `shell`,
/// `run_terminal_cmd`, `execute_command` are one thing wearing four names —
/// and a board that groups by raw name shows four columns for one activity.
/// The kind is the axis a UI groups and colours by; the raw name travels
/// alongside it in ``AgentEventKind/toolCallStarted(id:name:kind:target:)``.
public enum ToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A shell command or terminal invocation.
    case shell
    /// Reading a file, listing a directory, or fetching a notebook.
    case fileRead
    /// Any mutation of the working tree: write, edit, patch, delete.
    case fileWrite
    /// Grep, glob, or a codebase search index.
    case search
    /// A network fetch or a web search.
    case web
    /// A call into an MCP server. `target` names the server.
    case mcp
    /// Spawning a child agent — Claude's `Task`, Codex's `spawn_agent`.
    case subagent
    /// Plan-mode and todo-list bookkeeping tools.
    case plan
    /// Anything the adapter could not confidently place. Never a guess.
    case other
}

/// A pointer back into the source a fact came from, so a UI can offer
/// "show me the line".
///
/// Which fields are populated depends on the store: a JSONL transcript
/// gives `path` + `byteOffset` (+ `lineNumber` when the tailer counted),
/// a SQLite store gives `path` + `rowID`. Nothing here is required to
/// round-trip — a source can be rewritten or compacted between the
/// observation and the click — so a consumer must treat a miss as normal.
public struct RawRef: Hashable, Codable, Sendable {
    /// The file or database the event was read from.
    public let path: String
    /// Byte offset of the record within `path`, for file-backed sources.
    public let byteOffset: Int64?
    /// Row id of the record, for SQLite-backed sources.
    public let rowID: Int64?
    /// 1-based line number, when the tailer was counting lines anyway.
    public let lineNumber: Int?

    /// Creates a reference. Every locator but `path` is optional.
    public init(path: String, byteOffset: Int64? = nil, rowID: Int64? = nil, lineNumber: Int? = nil) {
        self.path = path
        self.byteOffset = byteOffset
        self.rowID = rowID
        self.lineNumber = lineNumber
    }
}

/// Why a turn stopped.
public enum TurnEndReason: String, Codable, Sendable, CaseIterable, Hashable {
    /// The model finished and yielded the floor back to the user.
    case complete
    /// A person interrupted it (escape, Ctrl-C, "stop").
    case aborted
    /// The harness reported a failure — API error, tool crash, context blowup.
    case error
    /// The source recorded an end without saying why.
    case unknown
}

/// Why a session stopped.
public enum SessionEndReason: String, Codable, Sendable, CaseIterable, Hashable {
    /// The harness exited normally and said so in its log.
    case exited
    /// The process was signalled.
    case killed
    /// No log said anything; the process simply is not there any more. This
    /// is the reason a liveness probe produces, and the only one that a
    /// later `liveness(alive: true)` may undo.
    case processGone
    /// The session stopped being updated and nothing explained it.
    case unknown
}

/// One observed fact about a session.
///
/// The whole point of this enum is that it is *harness-agnostic*: Codex
/// rollout items, Claude transcript lines, Cursor blob rows, and Grok
/// `updates.jsonl` records all collapse into these cases, so the reducer,
/// the store, and the board never learn a harness's private vocabulary.
///
/// A case exists only where a real store records the fact. Anything a
/// harness reports that has no equivalent here rides in
/// ``AgentEventKind/note(_:)`` rather than growing a case that six of the
/// eight harnesses would never emit.
///
/// Text-carrying state cases are previews, not content: adapters run every
/// string through ``EventText/preview(_:max:)`` before it reaches an event.
/// The one exception is ``textBody(role:text:toolCallID:)``, which exists so
/// a host that keeps a full-text index can receive bodies without the board
/// ever reading them — the reducer treats it as a heartbeat, and adapters cap
/// it at ``AgentEventKind/textBodyLimit`` bytes.
public enum AgentEventKind: Hashable, Codable, Sendable {
    /// First sighting of a session, carrying whatever identity the adapter
    /// could seed from the head of the source.
    case sessionStarted(identity: SessionIdentity)
    /// Later evidence about the session's identity. Only non-`nil` fields
    /// of the patch mean anything.
    case identityUpdated(SessionIdentityPatch)
    /// A person said something. `preview` is already truncated.
    case userPrompt(preview: String)
    /// The harness opened a turn. Some stores record this explicitly; for
    /// the ones that do not, ``userPrompt(preview:)`` opens the turn.
    case turnStarted
    /// Model reasoning was observed — a thinking block or a reasoning item.
    case thinking
    /// The model emitted prose. `preview` is already truncated.
    case assistantText(preview: String)
    /// A tool call began. `id` is the harness's own call id, `name` its raw
    /// tool name, `kind` the normalised activity, and `target` the file
    /// path, command, url, or MCP server the call is aimed at.
    case toolCallStarted(id: String, name: String, kind: ToolKind, target: String?)
    /// A tool call finished. `id` matches the `toolCallStarted` that opened it.
    case toolCallFinished(id: String, isError: Bool)
    /// The harness is blocked waiting for a person to approve something.
    case permissionRequested(id: String, tool: String?)
    /// The person answered. `allowed` is what they said.
    case permissionResolved(id: String, allowed: Bool)
    /// A child session was spawned. `child` is already a full ``SessionKey``
    /// because the adapter resolved which harness the child belongs to.
    case subagentStarted(child: SessionKey, agentType: String?, toolUseID: String?)
    /// A child session finished and stopped counting against the parent.
    case subagentFinished(child: SessionKey)
    /// The turn closed.
    case turnEnded(reason: TurnEndReason)
    /// Token accounting for one billed step. Counts are deltas, not totals —
    /// the reducer sums them.
    case usage(model: String?, inputTokens: Int, outputTokens: Int, cachedTokens: Int)
    /// The harness compacted or summarised its own context.
    case compaction
    /// The session ended, according to the source.
    case sessionEnded(reason: SessionEndReason)
    /// A liveness verdict from a process probe rather than from a log. Only
    /// a liveness resolver emits this; file parsers never do.
    case liveness(alive: Bool)
    /// Harness-specific information worth surfacing that has no case of its
    /// own — Grok phase names, Cursor mode switches. Display only: the
    /// reducer treats it as a heartbeat.
    case note(String)
    /// The full text of a prompt, an assistant message, or a tool result,
    /// for hosts that maintain a searchable index. Emitted *alongside* the
    /// preview-carrying state event, never instead of it. The reducer
    /// ignores it beyond the heartbeat; adapters truncate `text` to
    /// ``textBodyLimit`` and set `toolCallID` only for tool results.
    case textBody(role: TextBodyRole, text: String, toolCallID: String?)

    /// Upper bound (in UTF-8 bytes) adapters apply to
    /// ``textBody(role:text:toolCallID:)`` before emitting it. Big enough for
    /// any prompt a person types and most tool output; a multi-megabyte log
    /// dump is not something anyone searches for by content.
    public static let textBodyLimit = 32 * 1024
}

/// Who produced a ``AgentEventKind/textBody(role:text:toolCallID:)``.
public enum TextBodyRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case toolResult
}

/// One event about one session, at one point in time.
///
/// Two clocks matter and both are kept. `timestamp` is the source's own
/// notion of when the thing happened, which is what a transcript replay
/// must order by; `observedAt` is when Auspex read it, which is what
/// staleness and latency are measured against. For a live tail they are
/// within milliseconds; for a cold-start seed of a week-old transcript they
/// are a week apart, and conflating them would make every replayed session
/// look fresh.
///
/// `sequence` restores file order for events a source stamped with the same
/// timestamp — common, because a harness writes a whole turn's worth of
/// records in one flush. It is monotonic per tailer, not global, and `0`
/// means the source offered no ordering.
///
/// `id` is generated at construction and is *not* stable across replays: a
/// re-read of the same transcript line produces a new `AgentEvent` with a
/// new `id`. It exists for `Identifiable` in a UI list, and a store assigns
/// its own row id rather than trusting this one. Equality includes it, so
/// two independently constructed events describing the same source record
/// are not `==`; compare ``kind`` when that is what you mean.
public struct AgentEvent: Hashable, Codable, Sendable, Identifiable {
    /// Per-construction identity, for diffable UI lists. Not stable across
    /// replays; see the type's discussion.
    public let id: UUID
    /// The session this happened to.
    public let session: SessionKey
    /// The source's timestamp, or the observation time when the source did
    /// not record one.
    public let timestamp: Date
    /// When Auspex read the record.
    public let observedAt: Date
    /// Monotonic order within one tailer; `0` when the source has no order.
    public let sequence: Int64
    /// What happened.
    public let kind: AgentEventKind
    /// Where to look in the source to see the original record.
    public let raw: RawRef?

    /// Creates an event.
    ///
    /// `observedAt` defaults to `timestamp`, which is the right default for
    /// a live tail and for tests; a cold-start seed should pass the real
    /// observation time so replayed history is not mistaken for fresh
    /// activity.
    public init(
        id: UUID = UUID(),
        session: SessionKey,
        timestamp: Date,
        observedAt: Date? = nil,
        sequence: Int64 = 0,
        kind: AgentEventKind,
        raw: RawRef? = nil
    ) {
        self.id = id
        self.session = session
        self.timestamp = timestamp
        self.observedAt = observedAt ?? timestamp
        self.sequence = sequence
        self.kind = kind
        self.raw = raw
    }
}
