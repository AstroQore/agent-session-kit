import AgentSessionKit
import Foundation

/// Turns one line of one of Grok Build's session files into zero or more
/// ``AgentEvent``s.
///
/// Pure, static, and stateless, like ``CodexRecordMapper``: it is called from a
/// `@Sendable` decode closure inside a ``JSONLTailer``, once per line, with no
/// memory of the line before. What is different here is that a session is
/// *three* files and every interesting fact appears in at least two of them, so
/// the mapper is told which file a line came from and each fact is read out of
/// exactly one of them.
///
/// ## One source per fact
///
/// | Fact | Read from | Ignored in | Why |
/// | --- | --- | --- | --- |
/// | The person's prompt, and the turn it opens | `updates.user_message_chunk` | `chat_history.user` | Despite the name it is not a fragment: its text is byte-for-byte the `chat_history` record's, it is stamped, and there is exactly one per `turn_completed` on every session measured. The history record is the *model-facing* copy — wrapped in `<user_query>`, sitting between an injected `<user_info>` envelope and any number of `<system-reminder>` blocks that wear the same `type: "user"` — and older sessions do not mark which of them a person typed at all. |
/// | The model's prose | `updates.agent_message_chunk` | `chat_history.assistant` | Also not a fragment: one per assistant message, same length as the history record's `content`. Sessions exist whose history records carry no prose at all. |
/// | Reasoning | `updates.agent_thought_chunk` | `chat_history.reasoning` | One per reasoning block, and stamped, which the history record is not. |
/// | Tool call lifecycle and results | `updates.tool_call` / `tool_call_update` | `events.tool_started` / `tool_completed`, `chat_history.backend_tool_call` / `tool_result` | Only the updates carry a call id on *both* halves — `tool_started` carries none — and `tool_completed`'s id comes from the same namespace as the updates', so mapping both would close every local call twice. Every finished update carries `rawOutput`, one per `chat_history.tool_result`, so the history copy adds nothing but a body with no id to file it under. |
/// | Turn closing | `updates.turn_completed` **and** `events.turn_ended` | — | `turn_completed` is the one that pairs 1:1 with a prompt and names a `stop_reason`; `events.turn_ended` is the only record of a *cancellation category*. A second close is a no-op in ``SessionStateReducer`` and a missing one strands a row as "thinking" forever, so both are mapped. |
/// | Permission | `events.permission_requested` / `permission_resolved` | — | Nothing else records the block at all. |
/// | Model, and any non-primary relationship | `events.turn_started` | — | The only record that names the model. |
///
/// ## `turn_started` does not open a turn
///
/// It looks like it should, and it is the one mapping here that goes against
/// the obvious reading. `events.turn_started` is not written once per prompt:
/// across the corpus it pairs 1:1 with `events.turn_ended` and *not* with the
/// prompts — one session has three prompts, three `turn_completed`s, and a
/// single `turn_started`. Emitting ``AgentEventKind/turnStarted`` from it would
/// therefore under-count turns on some sessions and, because the reducer bumps
/// its counter for a `userPrompt` unconditionally, double-count them on the
/// sessions where the two records do line up. So `turn_started` contributes its
/// model and nothing else, and the prompt opens the turn — which is the case
/// ``AgentEventKind/turnStarted`` documents as the norm anyway.
///
/// ## What is deliberately dropped
///
/// - **`phase_changed`.** The highest-volume record in the store by two orders
///   of magnitude — 246,727 of them across a 120-session sample, essentially
///   all `streaming_text` or `streaming_reasoning`, which fire per token.
///   Nothing is emitted by default. ``Options/includePhaseNotes`` turns on a
///   note for the phases that are *not* per-token — `tool_execution`,
///   `waiting_for_model`, `permission_prompt`, and whatever a later release
///   adds — which is a handful per turn rather than several hundred.
/// - **Token counters.** `updates.turn_completed` carries a full `usage` object
///   (`inputTokens`, `cachedReadTokens`, `reasoningTokens`, a per-model
///   breakdown). It is not emitted as
///   ``AgentEventKind/usage(model:inputTokens:outputTokens:cachedTokens:)``
///   because the reducer *sums* what it is given, and nothing on disk settles
///   whether those counters are this turn's or the session's running total —
///   the `numTurns: 2` inside a single-turn session's record argues for the
///   second reading. Billing every turn from the start of the session is a
///   worse answer than reporting nothing. TODO: settle it against a session
///   whose turns are individually accounted for, then emit the delta.
/// - **`tool_started` / `tool_completed`, `first_token`, `loop_started`,
///   `hook_execution`, the successful half of the MCP handshake, and the
///   `goal_*` planner trace.** Bookkeeping, or a duplicate of something the
///   updates already carry with an id. Only `mcp_server_failed` and
///   `mcp_oauth_discovery_timeout` become notes, because a server that did not
///   start is why a tool is about to be missing.
/// - **Subagents.** `spawn_subagent` appears as a tool name and maps to
///   ``ToolKind/subagent``, but nothing on disk names the child session it
///   created: the CLI's update vocabulary has `subagent_progress` and
///   `subagent_finished`, neither of which appears in the corpus, and no
///   observed shape carries a child id. Emitting a finish for a child that was
///   never announced would put a key in the reducer's roster that nothing
///   created, so the spawn is reported as the tool call it is and no more. A
///   `turn_started.session_relationship` other than `"primary"` is recorded as
///   ``SessionIdentity/variant`` verbatim rather than resolved into a parent.
public enum GrokRecordMapper: Sendable {
    /// How much of a prompt or a reply travels in a preview.
    public static let previewLimit = 200

    /// The phases that fire per token rather than per transition.
    ///
    /// Named rather than allow-listing the other way round, so that a phase a
    /// later release adds is surfaced rather than silently dropped: the failure
    /// mode of a missing note is a quieter board, and the failure mode of a
    /// per-token note is a hundred events a second through a stream whose
    /// buffer is finite.
    public static let perTokenPhases: Set<String> = ["streaming_text", "streaming_reasoning"]

    /// What the mapper emits beyond the defaults.
    public struct Options: Sendable, Hashable {
        /// Emit ``AgentEventKind/note(_:)`` for `phase_changed` records whose
        /// phase is not in ``perTokenPhases``.
        ///
        /// Off by default. A note is a heartbeat to the reducer and a line of
        /// display to a host, and neither is worth the volume unless a host is
        /// actually rendering phases.
        public var includePhaseNotes: Bool

        /// Creates an options value.
        public init(includePhaseNotes: Bool = false) {
            self.includePhaseNotes = includePhaseNotes
        }

        /// Notes off — what a tailer uses unless a host asks otherwise.
        public static let `default` = Options()
    }

    // MARK: - Entry points

    /// Maps one line, told which file it came from.
    ///
    /// Total: a line that is not JSON, not a record of that file's shape, or of
    /// a type this adapter does not model yields `[]`. `now` becomes every
    /// event's ``AgentEvent/observedAt`` — and its ``AgentEvent/timestamp`` too,
    /// for the records that carry no clock of their own — so a week-old session
    /// replayed at cold start is not rendered as fresh activity.
    public static func events(
        from data: Data,
        file: GrokSourceFile,
        session: SessionKey,
        now: Date,
        options: Options = .default
    ) -> [AgentEvent] {
        switch file {
        case .events: eventsFromEvents(data, session: session, now: now, options: options)
        case .updates: eventsFromUpdates(data, session: session, now: now)
        case .chatHistory: eventsFromChatHistory(data, session: session, now: now)
        }
    }

    /// Maps one line of `events.jsonl`.
    public static func eventsFromEvents(
        _ data: Data,
        session: SessionKey,
        now: Date,
        options: Options = .default
    ) -> [AgentEvent] {
        guard let record = GrokEventRecord.decode(data) else { return [] }
        return events(from: record, session: session, now: now, options: options)
    }

    /// Maps one line of `updates.jsonl`.
    public static func eventsFromUpdates(
        _ data: Data,
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        guard let record = GrokUpdateRecord.decode(data) else { return [] }
        return events(from: record, session: session, now: now)
    }

    /// Maps one line of `chat_history.jsonl`.
    ///
    /// Not part of the default tail — see ``GrokLiveAdapter/defaultTailedFiles``
    /// and the type's table for why every fact it carries is taken from
    /// `updates.jsonl` instead. It exists for a host that wants the
    /// model-facing history as its source, and tailing it *alongside*
    /// `updates.jsonl` double-counts prompts and prose.
    public static func eventsFromChatHistory(
        _ data: Data,
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        guard let record = GrokChatRecord.decode(data) else { return [] }
        return events(from: record, session: session, now: now)
    }

    // MARK: - events.jsonl

    /// Maps an already-parsed `events.jsonl` record.
    public static func events(
        from record: GrokEventRecord,
        session: SessionKey,
        now: Date,
        options: Options = .default
    ) -> [AgentEvent] {
        var emitter = Emitter(session: session, timestamp: record.timestamp ?? now, now: now)
        let fields = record.fields

        switch record.type {
        case "turn_started":
            turnStarted(fields, session: session, into: &emitter)

        case "turn_ended", "turn_aborted", "turn_failed":
            // `cancellation_category` is the only place on disk a stopped turn
            // says it was stopped, and it is present exactly when one was.
            let reason = fields["cancellation_category"] != nil
                ? TurnEndReason.aborted
                : fields.firstString("outcome", "reason", "stop_reason", "status")
                    .map(turnEndReason) ?? .complete
            emitter.add(.turnEnded(reason: reason))

        case "permission_requested":
            let tool = fields["tool_name"]?.string
            emitter.add(.permissionRequested(id: permissionID(tool: tool), tool: tool))

        case "permission_resolved":
            let tool = fields["tool_name"]?.string
            emitter.add(
                .permissionResolved(
                    id: permissionID(tool: tool),
                    allowed: isAllowed(fields["decision"]?.string)
                )
            )

        case "phase_changed":
            guard options.includePhaseNotes,
                  let phase = fields["phase"]?.string,
                  !perTokenPhases.contains(phase)
            else { break }
            emitter.add(.note("phase: \(EventText.preview(phase, max: 80))"))

        case "mcp_server_failed":
            let server = fields["server_name"]?.string ?? "server"
            let reason = fields.firstString("error_type", "error_message") ?? "failed to start"
            emitter.add(.note("mcp \(server): \(EventText.preview(reason, max: 160))"))

        case "mcp_oauth_discovery_timeout":
            let server = fields["server_name"]?.string ?? "server"
            emitter.add(.note("mcp \(server): oauth discovery timed out"))

        default:
            // `first_token`, `loop_started`, the successful half of the MCP
            // handshake, the `goal_*` planner trace, and the
            // `tool_started` / `tool_completed` pair whose ids the updates
            // already own. See the type's table.
            break
        }
        return emitter.events
    }

    /// The one record that names the model and the session's relationship to
    /// any parent.
    ///
    /// Deliberately *not* a ``AgentEventKind/turnStarted`` — see the type's
    /// discussion of why this record does not mark a turn.
    private static func turnStarted(
        _ fields: GrokJSON,
        session: SessionKey,
        into emitter: inout Emitter
    ) {
        // A `turn_started` that names a different session is not this session's.
        // Grok writes one file set per session, so this only fires on a
        // directory that was copied — either way, taking its model would be
        // taking another session's.
        if let id = fields["session_id"]?.string,
           id.caseInsensitiveCompare(session.sessionID) != .orderedSame {
            return
        }
        var patch = SessionIdentityPatch()
        patch.model = fields["model_id"]?.string
        if let relationship = fields["session_relationship"]?.string, relationship != "primary" {
            // The corpus only ever says `"primary"`. Anything else is recorded
            // verbatim rather than interpreted: with no observed child there is
            // no way to know which session it points at, and inventing a parent
            // key is worse than leaving one unset.
            patch.variant = relationship
        }
        guard !patch.isEmpty else { return }
        emitter.add(.identityUpdated(patch))
    }

    // MARK: - updates.jsonl

    /// Maps an already-parsed `updates.jsonl` record.
    public static func events(
        from record: GrokUpdateRecord,
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        // A line stamped with another session's id belongs to another session's
        // stream. Same reasoning as `turn_started`.
        if let id = record.sessionID, id.caseInsensitiveCompare(session.sessionID) != .orderedSame {
            return []
        }
        var emitter = Emitter(session: session, timestamp: record.timestamp ?? now, now: now)
        let update = record.update

        switch record.updateType {
        case "user_message_chunk":
            let text = chunkText(update)
            guard !text.isEmpty else { break }
            emitter.add(.userPrompt(preview: EventText.preview(text, max: previewLimit)))
            if let body = body(text) {
                emitter.add(.textBody(role: .user, text: body, toolCallID: nil))
            }

        case "agent_message_chunk":
            let text = chunkText(update)
            guard !text.isEmpty else { break }
            emitter.add(.assistantText(preview: EventText.preview(text, max: previewLimit)))
            if let body = body(text) {
                emitter.add(.textBody(role: .assistant, text: body, toolCallID: nil))
            }

        case "agent_thought_chunk":
            emitter.add(.thinking)

        case "tool_call":
            guard let id = update["toolCallId"]?.string, !id.isEmpty else { break }
            let kind = GrokToolCall.kind(update)
            emitter.add(
                .toolCallStarted(
                    id: id,
                    name: GrokToolCall.name(update),
                    kind: kind,
                    target: GrokToolCall.target(kind: kind, update: update).map(shorten)
                )
            )

        case "tool_call_update":
            guard let id = update["toolCallId"]?.string, !id.isEmpty,
                  let status = update["status"]?.string
            else { break }
            // `in_progress`, and an update carrying only a refined `title` or
            // `kind`, say nothing about the call *finishing*. The event model
            // has no case for a call being amended, and inventing a second
            // start would double the tool count.
            guard status == "completed" || status == "failed" else { break }
            emitter.add(.toolCallFinished(id: id, isError: status == "failed"))
            if let text = body(GrokToolCall.resultText(update)) {
                emitter.add(.textBody(role: .toolResult, text: text, toolCallID: id))
            }

        case "turn_completed":
            let reason = update.firstString("stop_reason", "reason")
            emitter.add(.turnEnded(reason: reason.map(turnEndReason) ?? .complete))

        case "compaction_checkpoint":
            emitter.add(.compaction)

        default:
            // `hook_execution`, `subagent_progress`, `diff_review`, and
            // everything a later release adds.
            break
        }
        return emitter.events
    }

    /// The text of a `*_message_chunk` / `*_thought_chunk` update.
    private static func chunkText(_ update: GrokJSON) -> String {
        update["content"]?.joinedText ?? ""
    }

    // MARK: - chat_history.jsonl

    /// Maps an already-parsed `chat_history.jsonl` record.
    ///
    /// These records carry no timestamp, so everything here is stamped with
    /// `now`. That is one of the reasons the file is not tailed by default: the
    /// fan-out tailer merges its files by timestamp, and an undated record
    /// sorts to the moment it was read rather than the moment it happened.
    public static func events(
        from record: GrokChatRecord,
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        var emitter = Emitter(session: session, timestamp: now, now: now)
        let fields = record.fields

        switch record.type {
        case "user":
            // Three things wear `type: "user"` in this file: the `<user_info>`
            // envelope the harness prepends, the `<system-reminder>` blocks it
            // injects mid-conversation, and something a person typed. Only the
            // third carries `prompt_index` and only the second carries
            // `synthetic_reason`, so requiring the first and refusing the second
            // keeps the turn count to turns a person opened — on the sessions
            // that write `prompt_index` at all, which is why this file is not
            // where prompts are read from.
            guard fields["synthetic_reason"] == nil, fields["prompt_index"]?.int != nil else {
                break
            }
            let text = unwrapPrompt(fields["content"]?.joinedText ?? "")
            guard !text.isEmpty else { break }
            emitter.add(.userPrompt(preview: EventText.preview(text, max: previewLimit)))
            if let body = body(text) {
                emitter.add(.textBody(role: .user, text: body, toolCallID: nil))
            }

        case "assistant":
            let text = fields["content"]?.joinedText ?? ""
            guard !text.isEmpty else { break }
            emitter.add(.assistantText(preview: EventText.preview(text, max: previewLimit)))
            if let body = body(text) {
                emitter.add(.textBody(role: .assistant, text: body, toolCallID: nil))
            }

        case "reasoning":
            emitter.add(.thinking)

        default:
            // `system` is the prompt the harness wrote, not the session's;
            // `backend_tool_call` records a call with no id to file it under;
            // `tool_result` repeats a body the updates already carry with its
            // call id.
            break
        }
        return emitter.events
    }

    // MARK: - Shared vocabulary

    /// The id a permission prompt is tracked under.
    ///
    /// Grok records no id for a permission at all — `permission_requested` and
    /// `permission_resolved` carry a `tool_name`, a timestamp, and nothing
    /// else — so the mapper mints one the *same way twice*, which is the only
    /// property that matters: ``SessionStateReducer`` clears a prompt when a
    /// resolution arrives carrying the id the request had, and a scheme derived
    /// from anything per-record (a timestamp, a line number) would never match.
    ///
    /// The limitation this buys: two prompts open for the *same tool* at once
    /// share an id, so the first resolution clears both. That is a faithful
    /// degradation rather than a lossy one — the reducer tracks a single open
    /// permission because a harness blocks on a prompt, and a harness that is
    /// blocked is not opening a second one.
    ///
    /// Worth knowing about the volume: on the corpus there is one
    /// `permission_requested` per tool call, auto-approved ones included, and
    /// those resolve in the same millisecond with `wait_ms: 0`. A board that
    /// renders per event sees a flicker; one that renders the snapshot after a
    /// batch sees nothing, which is the truth.
    public static func permissionID(tool: String?) -> String {
        "perm:" + (tool ?? "tool")
    }

    /// Whether a `permission_resolved` decision let the tool run.
    ///
    /// Anything not recognisably an approval counts as a refusal. `"allow"` is
    /// the value the corpus carries and the CLI spells always-approvals with an
    /// `allow` prefix too; a decision this table has never seen is likelier to
    /// be a new way of saying no — a timeout, an escalation, a rule that
    /// pre-denied it — than a new way of saying yes.
    static func isAllowed(_ decision: String?) -> Bool {
        guard let decision = decision?.lowercased() else { return false }
        return decision.hasPrefix("allow") || decision == "approved" || decision == "accept"
    }

    /// Maps a harness stop reason onto ``TurnEndReason``.
    static func turnEndReason(_ raw: String) -> TurnEndReason {
        let reason = raw.lowercased()
        if reason.contains("cancel") || reason.contains("abort") || reason.contains("interrupt")
            || reason.hasPrefix("user_") {
            return .aborted
        }
        if reason.contains("error") || reason.contains("fail") { return .error }
        switch reason {
        case "end_turn", "complete", "completed", "done", "stop", "stop_sequence", "success":
            return .complete
        default:
            return .unknown
        }
    }

    /// Strips the `<user_query>` envelope the harness wraps a prompt in before
    /// showing it to the model.
    ///
    /// Mechanical and added by the harness rather than by the person, so
    /// removing it makes a preview show what was typed instead of showing
    /// markup. Anything that is not exactly the envelope is returned untouched.
    /// Only `chat_history` records carry it; `updates.user_message_chunk` is
    /// the raw prompt already.
    static func unwrapPrompt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<user_query>"
        let close = "</user_query>"
        guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
              trimmed.count > open.count + close.count
        else { return text }
        return String(trimmed.dropFirst(open.count).dropLast(close.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool target, short enough for a status row.
    private static func shorten(_ target: String) -> String {
        EventText.preview(target, max: previewLimit)
    }

    /// A full-text body, capped at ``AgentEventKind/textBodyLimit`` bytes, or
    /// `nil` when there is nothing to carry.
    ///
    /// Cut on a scalar boundary rather than a byte one: a body sliced through a
    /// multi-byte character reaches a full-text index as mojibake, and a tool
    /// that dumps a UTF-8 log is exactly the one that overruns the cap.
    static func body(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let limit = AgentEventKind.textBodyLimit
        guard text.utf8.count > limit else { return text }
        var out = ""
        out.reserveCapacity(limit)
        var bytes = 0
        for scalar in text.unicodeScalars {
            let width = utf8Width(scalar)
            if bytes + width > limit { break }
            out.unicodeScalars.append(scalar)
            bytes += width
        }
        return out.isEmpty ? nil : out
    }

    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: 1
        case 0x80..<0x800: 2
        case 0x800..<0x1_0000: 3
        default: 4
        }
    }

    /// Stamps every event with the session and the two clocks, and nothing
    /// else — the tailer owns `sequence` and fills in ``AgentEvent/raw``.
    private struct Emitter {
        let session: SessionKey
        let timestamp: Date
        let now: Date
        var events: [AgentEvent] = []

        mutating func add(_ kind: AgentEventKind) {
            events.append(
                AgentEvent(session: session, timestamp: timestamp, observedAt: now, kind: kind)
            )
        }
    }
}
