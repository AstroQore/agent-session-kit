import AgentSessionKit
import Foundation

/// Turns one Claude Code transcript line into ``AgentEvent``s.
///
/// Pure, stateless, and total: same bytes in, same events out, no clock of its
/// own beyond the `now` it is handed, and never a throw. A line it cannot make
/// sense of yields `[]`, which is what ``JSONLTailer`` expects of a decoder
/// and what keeps one malformed record from stopping a tail.
///
/// It deliberately does not set ``AgentEvent/sequence`` or ``AgentEvent/raw``.
/// The tailer owns both — it is the thing that knows the byte offset and the
/// order lines arrived in — and a decoder that filled them in would be
/// guessing at facts it does not have.
///
/// ## Record → event
///
/// | Record | Events |
/// | --- | --- |
/// | any fully-stamped record | `identityUpdated(cwd, gitBranch, entrypoint, model)` |
/// | `user`, human text | `userPrompt(preview:)`, `textBody(.user, …)` |
/// | `user`, `isMeta: true` | *nothing* — injected context, not a person |
/// | `user`, `tool_result` blocks | `toolCallFinished(id:isError:)`, `textBody(.toolResult, …, toolCallID:)` |
/// | `assistant`, `thinking` block | `thinking` |
/// | `assistant`, `text` block | `assistantText(preview:)`, `textBody(.assistant, …)` |
/// | `assistant`, `tool_use` block | `toolCallStarted(id:name:kind:target:)` |
/// | `assistant`, `message.usage` | `usage(model:input:output:cached:)` |
/// | `assistant`, `stop_reason: end_turn` with no `tool_use` | `turnEnded(.complete)` |
/// | `custom-title` | `identityUpdated(title:)` |
/// | `worktree-state` | `identityUpdated(cwd:gitBranch:)` |
/// | `queue-operation` | `note("queued: …")` |
/// | `system` / `subtype: compact_boundary`, `compact-boundary`, `summary` | `compaction` |
/// | `mode`, `pr-link`, `attachment`, `last-prompt`, `file-history-snapshot`, anything unknown | *nothing* |
///
/// ## Judgement calls
///
/// - **An identity patch per stamped record, not per session.** The mapper
///   cannot know which record is "first" — it sees one line. Emitting the
///   patch every time is what makes a mid-session `cd` or a branch switch
///   visible at all, and ``ClaudeIdentityFilter`` collapses the repeats before
///   they reach a stream. A patch is idempotent in the reducer either way.
/// - **`subagentStarted` is never emitted here.** The parent's `Task` line
///   records a tool-use id and nothing that identifies the child, whose
///   `agentId` is invented later and only ever appears in the child's own
///   file. Linking is ``ClaudeSubagentLinker``'s job; the parent line becomes
///   an ordinary ``ToolKind/subagent`` tool call.
/// - **Only `end_turn` closes a turn.** `stop_reason: tool_use` means the
///   model is still working, and `stop_sequence` / `max_tokens` mean it was
///   cut off mid-thought — neither is a turn a person got an answer from. A
///   turn that never closes stays `thinking` until the next prompt, which is
///   the honest reading of a transcript that stops mid-turn.
/// - **A tool result's text prefers the `toolUseResult` sidecar.** The
///   `tool_result` block holds what the *model* was shown, which for a large
///   output is a truncated rendering with a pointer to a spill file; the
///   sidecar holds the `stdout`/`stderr` that actually ran. When there is
///   more than one result block on the record the sidecar cannot be attributed
///   to either, so each block falls back to its own content.
/// - **Auxiliary records are stamped `now`.** `custom-title`, `mode`,
///   `queue-operation`, and `worktree-state` carry no timestamp at all. Using
///   the observation clock keeps them ordered after the conversation records
///   that precede them, which is where the harness wrote them.
public enum ClaudeRecordMapper: Sendable {
    /// Characters kept in a `userPrompt` or `assistantText` preview.
    public static let previewLimit = 200

    /// Maps one transcript line.
    ///
    /// - Parameters:
    ///   - data: The raw bytes of one JSONL line, newline excluded.
    ///   - session: The key events are attributed to. For a subagent file this
    ///     is the *child's* key, not the parent's.
    ///   - isSubagent: Whether `data` came from a `subagents/agent-*.jsonl`.
    ///     Only used to keep a child's identity patches from claiming the
    ///     parent's `entrypoint`.
    ///   - now: The observation clock. Becomes ``AgentEvent/observedAt`` on
    ///     every event, and ``AgentEvent/timestamp`` on the auxiliary records
    ///     that carry none.
    public static func events(
        from data: Data,
        session: SessionKey,
        isSubagent: Bool,
        now: Date
    ) -> [AgentEvent] {
        guard let record = ClaudeTranscriptRecord.decode(data) else { return [] }
        return events(for: record, session: session, isSubagent: isSubagent, now: now)
    }

    /// Maps an already-parsed record. Split out so the adapter can reuse a
    /// record it parsed for another reason without paying for the JSON twice.
    public static func events(
        for record: ClaudeTranscriptRecord,
        session: SessionKey,
        isSubagent: Bool,
        now: Date
    ) -> [AgentEvent] {
        var kinds: [AgentEventKind] = []

        if record.isFullyStamped, let patch = identityPatch(record, isSubagent: isSubagent) {
            kinds.append(.identityUpdated(patch))
        }

        switch record.type {
        case "user":
            kinds.append(contentsOf: userKinds(record))
        case "assistant":
            kinds.append(contentsOf: assistantKinds(record))
        case "custom-title":
            if let title = record.customTitle {
                kinds.append(.identityUpdated(SessionIdentityPatch(
                    title: EventText.preview(title, max: previewLimit)
                )))
            }
        case "worktree-state":
            if let patch = worktreePatch(record) {
                kinds.append(.identityUpdated(patch))
            }
        case "queue-operation":
            if let note = queueNote(record) {
                kinds.append(.note(note))
            }
        case "system":
            if record.subtype == "compact_boundary" { kinds.append(.compaction) }
        case "compact-boundary", "summary":
            kinds.append(.compaction)
        default:
            // `mode`, `pr-link`, `attachment`, `last-prompt`,
            // `file-history-snapshot`, `relocated`, `agent-name`,
            // `permission-mode`, `bridge-session`, `frame-link`, and whatever
            // the next release adds. None of them is a fact the event model
            // has a case for, and a `note` per attachment would be noise on
            // every board that renders one.
            break
        }

        guard !kinds.isEmpty else { return [] }
        let timestamp = record.timestamp ?? now
        return kinds.map {
            AgentEvent(session: session, timestamp: timestamp, observedAt: now, kind: $0)
        }
    }

    // MARK: - Identity

    private static func identityPatch(
        _ record: ClaudeTranscriptRecord,
        isSubagent: Bool
    ) -> SessionIdentityPatch? {
        let patch = SessionIdentityPatch(
            cwd: record.cwd,
            gitBranch: record.gitBranch,
            model: record.model,
            // A subagent inherits the parent's entrypoint on every line, which
            // would make the child look like a session a person started. Its
            // variant says what it actually is.
            entrypoint: isSubagent ? nil : record.entrypoint,
            variant: isSubagent ? ClaudeLiveAdapter.subagentVariant : nil
        )
        return patch.isEmpty ? nil : patch
    }

    /// A worktree hand-off moves the session's working directory and branch.
    /// `originalCwd` is where it came *from*, so it is deliberately not used:
    /// the identity should say where the session is now.
    private static func worktreePatch(_ record: ClaudeTranscriptRecord) -> SessionIdentityPatch? {
        guard let worktree = record.worktree else { return nil }
        let patch = SessionIdentityPatch(
            cwd: worktree.worktreePath,
            gitBranch: worktree.worktreeBranch
        )
        return patch.isEmpty ? nil : patch
    }

    private static func queueNote(_ record: ClaudeTranscriptRecord) -> String? {
        guard let operation = record.queueOperation else { return nil }
        guard let content = record.queueContent else { return "queued: \(operation)" }
        return "queued: \(operation) — \(EventText.preview(content, max: 80))"
    }

    // MARK: - Conversation

    private static func userKinds(_ record: ClaudeTranscriptRecord) -> [AgentEventKind] {
        if record.isToolResultRecord {
            return toolResultKinds(record)
        }
        // Skill preambles, hook output, and command envelopes all arrive as
        // `type: "user"`. `isMeta` is the harness's own flag for them, and it
        // is the only reliable one — the text itself looks like a prompt.
        guard !record.isMeta else { return [] }
        let text = plainText(record.content)
        guard !text.isEmpty else { return [] }
        return [
            .userPrompt(preview: EventText.preview(text, max: previewLimit)),
            .textBody(role: .user, text: bounded(text), toolCallID: nil)
        ]
    }

    private static func toolResultKinds(_ record: ClaudeTranscriptRecord) -> [AgentEventKind] {
        let results = record.content.compactMap { block -> (String, String, Bool)? in
            guard case let .toolResult(id, text, isError) = block else { return nil }
            return (id, text, isError)
        }
        // One result block is the overwhelmingly common case, and the only one
        // where the sidecar can be attributed with certainty.
        let sidecar = results.count == 1 ? record.toolResultSidecarText : nil
        var kinds: [AgentEventKind] = []
        for (id, text, isError) in results {
            kinds.append(.toolCallFinished(id: id, isError: isError))
            let body = sidecar ?? text
            guard !body.isEmpty else { continue }
            kinds.append(.textBody(role: .toolResult, text: bounded(body), toolCallID: id))
        }
        return kinds
    }

    private static func assistantKinds(_ record: ClaudeTranscriptRecord) -> [AgentEventKind] {
        var kinds: [AgentEventKind] = []
        var sawToolUse = false

        for block in record.content {
            switch block {
            case .thinking:
                kinds.append(.thinking)
            case let .text(text):
                let trimmed = EventText.collapseWhitespace(text)
                guard !trimmed.isEmpty else { continue }
                kinds.append(.assistantText(preview: EventText.preview(text, max: previewLimit)))
                kinds.append(.textBody(role: .assistant, text: bounded(text), toolCallID: nil))
            case let .toolUse(id, name, input):
                sawToolUse = true
                let mapping = ClaudeToolMapping.resolve(name: name, input: input)
                kinds.append(.toolCallStarted(
                    id: id, name: name, kind: mapping.kind, target: mapping.target
                ))
            case .toolResult, .other:
                continue
            }
        }

        if let usage = record.usage {
            kinds.append(.usage(
                model: record.model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cachedTokens: usage.cachedTokens
            ))
        }

        // A turn that ended while a tool call is open did not end; the record
        // just happens to carry both, which Claude Code does not do today but
        // which costs nothing to be right about.
        if record.stopReason == "end_turn", !sawToolUse {
            kinds.append(.turnEnded(reason: .complete))
        }
        return kinds
    }

    // MARK: - Text

    /// Every `text` block of a record, joined. A prompt with an image in it
    /// arrives as `[image, text]`, and only the text half is a prompt.
    private static func plainText(_ blocks: [ClaudeContentBlock]) -> String {
        let parts = blocks.compactMap { block -> String? in
            guard case let .text(text) = block else { return nil }
            return text
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates to ``AgentEventKind/textBodyLimit`` *bytes*, cutting on a
    /// character boundary so a multi-byte scalar is never split in half.
    static func bounded(_ text: String) -> String {
        let limit = AgentEventKind.textBodyLimit
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > limit { break }
            kept.append(character)
            used += width
        }
        return kept
    }
}

/// The normalised activity behind a Claude Code tool name, and what the call
/// is aimed at.
///
/// A board groups by ``ToolKind``, so the table below is what decides whether
/// `Read`, `Glob`, and `Grep` are one column or three. Anything unrecognised
/// is ``ToolKind/other`` rather than a guess: a wrong kind colours a row
/// wrongly and is harder to notice than a grey one.
public enum ClaudeToolMapping: Sendable {
    /// A resolved tool call: what it does, and what it does it to.
    public struct Resolution: Hashable, Sendable {
        /// The normalised activity.
        public let kind: ToolKind
        /// The path, command, url, query, or server the call is aimed at,
        /// already truncated for display.
        public let target: String?
    }

    /// Characters kept in a tool call's `target`.
    public static let targetLimit = 120

    /// The prefix Claude Code gives every MCP tool: `mcp__<server>__<tool>`.
    public static let mcpPrefix = "mcp__"

    /// Resolves one tool call.
    ///
    /// - Parameters:
    ///   - name: The raw tool name from the `tool_use` block.
    ///   - input: The whitelisted subset of the call's input — see
    ///     ``ClaudeTranscriptRecord/toolInputKeys``.
    public static func resolve(name: String, input: [String: String]) -> Resolution {
        if name.hasPrefix(mcpPrefix) {
            return Resolution(kind: .mcp, target: server(inMCPName: name))
        }
        switch name {
        case "Bash", "BashOutput", "KillShell", "KillBash":
            return Resolution(kind: .shell, target: display(input["command"]))
        case "Read", "NotebookRead", "LS":
            return Resolution(
                kind: .fileRead,
                target: display(input["file_path"] ?? input["notebook_path"] ?? input["path"])
            )
        case "Glob", "Grep", "ToolSearch", "SearchSkills", "SearchPlugins":
            return Resolution(
                kind: .search,
                target: display(input["pattern"] ?? input["glob"] ?? input["query"] ?? input["path"])
            )
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return Resolution(
                kind: .fileWrite,
                target: display(input["file_path"] ?? input["notebook_path"] ?? input["path"])
            )
        case "WebFetch", "WebSearch":
            return Resolution(kind: .web, target: display(input["url"] ?? input["query"]))
        case "Task", "Agent":
            return Resolution(
                kind: .subagent,
                target: display(input["description"] ?? input["subagent_type"])
            )
        case "EnterPlanMode", "ExitPlanMode", "TodoWrite", "TaskCreate", "TaskUpdate",
             "TaskList", "TaskStop", "ExitWorktree", "EnterWorktree":
            return Resolution(kind: .plan, target: display(input["description"]))
        default:
            return Resolution(kind: .other, target: display(input["description"] ?? input["file_path"]))
        }
    }

    /// The server half of `mcp__<server>__<tool>`, or the whole name when it
    /// does not have the shape after all.
    static func server(inMCPName name: String) -> String? {
        let body = name.dropFirst(mcpPrefix.count)
        guard let separator = body.range(of: "__") else {
            return body.isEmpty ? nil : String(body)
        }
        return String(body[body.startIndex..<separator.lowerBound])
    }

    private static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let preview = EventText.preview(value, max: targetLimit)
        return preview.isEmpty ? nil : preview
    }
}

/// Collapses ``AgentEventKind/identityUpdated(_:)`` events that would tell a
/// consumer something it already knows.
///
/// ``ClaudeRecordMapper`` emits a patch for every fully-stamped record,
/// because a stateless line decoder has no way to tell the first one from the
/// nine hundredth. On a busy session that is one redundant event per line —
/// each of which touches the stream, the reducer, the store, and a diffable UI
/// list — so the tailer runs them through this and forwards only the fields
/// that actually changed.
///
/// Not a cache with an eviction policy: one of these lives inside one tailer,
/// holds at most eight small strings, and dies with it.
struct ClaudeIdentityFilter {
    private var cwd: String?
    private var gitBranch: String?
    private var title: String?
    private var model: String?
    private var entrypoint: String?
    private var variant: String?

    /// Returns `patch` with every already-known field cleared, or `nil` when
    /// nothing in it is new.
    mutating func reduce(_ patch: SessionIdentityPatch) -> SessionIdentityPatch? {
        var fresh = SessionIdentityPatch(pid: patch.pid, procStart: patch.procStart)
        if let value = patch.cwd, value != cwd { cwd = value; fresh.cwd = value }
        if let value = patch.gitBranch, value != gitBranch { gitBranch = value; fresh.gitBranch = value }
        if let value = patch.title, value != title { title = value; fresh.title = value }
        if let value = patch.model, value != model { model = value; fresh.model = value }
        if let value = patch.entrypoint, value != entrypoint { entrypoint = value; fresh.entrypoint = value }
        if let value = patch.variant, value != variant { variant = value; fresh.variant = value }
        return fresh.isEmpty ? nil : fresh
    }

    /// Seeds the filter from what discovery already put in a
    /// ``SessionSource/seedIdentity``, so the first line of a transcript does
    /// not re-announce facts the source arrived with.
    mutating func prime(with identity: SessionIdentity) {
        cwd = identity.cwd
        gitBranch = identity.gitBranch
        title = identity.title
        model = identity.model
        entrypoint = identity.entrypoint
        variant = identity.variant
    }
}
