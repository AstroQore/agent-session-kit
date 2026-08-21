import AgentSessionKit
import Foundation

/// Turns one Codex rollout line into zero or more ``AgentEvent``s.
///
/// Pure, static, and stateless. It is called from a `@Sendable` decode
/// closure inside ``JSONLTailer``, once per line, with no memory of the line
/// before — which is the constraint that shapes every decision below. A
/// mapper that could remember would dedupe by tracking ids; this one dedupes
/// by *choosing a source* for each fact and ignoring the other.
///
/// ## Where Codex says the same thing twice
///
/// Codex writes a rollout for two audiences at once: `response_item` records
/// are what it sent to (and received from) the model, and `event_msg` records
/// are what it showed the person sitting in front of it. Three facts appear
/// in both, and each is taken from exactly one side:
///
/// | Fact | Taken from | Ignored | Why |
/// | --- | --- | --- | --- |
/// | The person's prompt | `event_msg.user_message` | `response_item.message role=user` | The reducer counts a turn per ``AgentEventKind/userPrompt(preview:)``, so there must be exactly one. The `event_msg` is the one that marks a *human* turn: the desktop app also sends the model user-role messages carrying injected plugin catalogues and chat references, which are context, not something anybody typed. |
/// | The model's prose | `response_item.message role=assistant` | `event_msg.agent_message` | Both carry the same text; the `response_item` is the record every Codex vintage writes, and `agent_message` also fires for intermediate phases. |
/// | Reasoning | both | — | ``AgentEventKind/thinking`` carries no text and the reducer treats a repeat as a heartbeat, so emitting one per record costs nothing and keeps a rollout that writes only one of the two from looking idle. |
///
/// The consequence worth stating plainly: a rollout from a Codex vintage that
/// never wrote `user_message` would produce no turns. That vintage has not
/// been seen — the record is in every rollout on the corpus this was built
/// against — and the alternative, counting both, double-counts every turn in
/// every current rollout.
///
/// ## Where a tool call hides
///
/// The desktop app runs everything through one JavaScript `exec` tool, and
/// what that script *did* — patched a file, searched the web, called an MCP
/// server — is only ever recorded in the matching `*_end` event, never as a
/// `response_item`. Those events are therefore not ignored wholesale. The
/// discriminator is the call id: a `call_…` id belongs to a `response_item`
/// that already produced a pair of events, so the `*_end` is dropped as a
/// duplicate; an `exec-…` id belongs to nothing else, so the `*_end` is
/// expanded into a started/finished pair of its own. See
/// ``isResponseItemCallID(_:)``.
public enum CodexRecordMapper: Sendable {
    /// How much of a prompt or a reply travels in a preview.
    public static let previewLimit = 200

    /// Parses one JSONL line and maps it.
    ///
    /// Total: a line that is not JSON, not a rollout record, or of a type this
    /// adapter does not model yields `[]`. `now` becomes every event's
    /// ``AgentEvent/observedAt`` — and its ``AgentEvent/timestamp`` too, when
    /// the record carried none — so that a week-old transcript replayed at
    /// cold start is not rendered as fresh activity.
    public static func events(from data: Data, session: SessionKey, now: Date) -> [AgentEvent] {
        guard let record = CodexRolloutRecord.decode(data) else { return [] }
        return events(from: record, session: session, now: now)
    }

    /// Maps an already-parsed record.
    public static func events(
        from record: CodexRolloutRecord,
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        var emitter = Emitter(session: session, timestamp: record.timestamp ?? now, now: now)
        let payload = record.payload

        switch record.type {
        case "session_meta":
            sessionMeta(payload, session: session, into: &emitter)
        case "turn_context":
            turnContext(payload, into: &emitter)
        case "response_item":
            responseItem(payload, into: &emitter)
        case "event_msg":
            eventMessage(payload, session: session, into: &emitter)
        case "compacted":
            emitter.add(.compaction)
        default:
            // `world_state`, `inter_agent_communication_metadata`, and
            // whatever the next Codex release adds. Nothing to say about a
            // session, and a note per record would be noise per turn.
            break
        }
        return emitter.events
    }

    /// The normalised activity behind a Codex tool name.
    public static func toolKind(for name: String) -> ToolKind {
        CodexToolCall.kind(for: name)
    }

    /// `true` when `id` is a call id minted by the Responses API, which means
    /// a `response_item` for the same call is in the rollout too.
    ///
    /// The desktop app mints its own ids for the work a sandbox script did,
    /// prefixed `exec-`, and those appear in no `response_item` at all. The
    /// prefix is the only thing separating "this `*_end` is a duplicate" from
    /// "this `*_end` is the only record of a file being written".
    public static func isResponseItemCallID(_ id: String) -> Bool {
        id.hasPrefix("call_")
    }

    // MARK: - Envelopes

    /// The rollout header: cwd, which Codex surface wrote it, and nothing
    /// that would reset the session.
    ///
    /// Deliberately *not* ``AgentEventKind/sessionStarted(identity:)``. A
    /// forked thread replays its ancestors' headers at the top of its own
    /// rollout — three `session_meta` lines for a twice-forked thread — and a
    /// `sessionStarted` per header would clear the reducer's pending set three
    /// times before the first turn. Discovery announces the session; this only
    /// refines it.
    ///
    /// The ancestors are skipped by id: a header whose `id` names a different
    /// thread describes a different thread, and its cwd is not this session's.
    private static func sessionMeta(
        _ payload: CodexJSON,
        session: SessionKey,
        into emitter: inout Emitter
    ) {
        if let id = payload.firstString("id", "session_id"),
           id.caseInsensitiveCompare(session.sessionID) != .orderedSame {
            return
        }
        var patch = SessionIdentityPatch()
        patch.cwd = payload["cwd"]?.string
        patch.variant = payload["originator"]?.string
        patch.entrypoint = entrypoint(payload)
        guard !patch.isEmpty else { return }
        emitter.add(.identityUpdated(patch))
    }

    /// Where the session was started from.
    ///
    /// `source` is a string for an ordinary thread (`"vscode"`, `"cli"`) and
    /// an object for a thread Codex spawned itself
    /// (`{"subagent": {"other": "guardian"}}`), in which case its single key
    /// names the flavour. Falling back to `originator` keeps the field
    /// populated for the vintages that wrote no `source` at all.
    private static func entrypoint(_ payload: CodexJSON) -> String? {
        guard let source = payload["source"] else { return payload["originator"]?.string }
        if let value = source.string { return value }
        if let members = source.object, let key = members.keys.sorted().first { return key }
        return payload["originator"]?.string
    }

    /// The per-turn context: the only place a rollout names its model.
    ///
    /// The approval policy and the sandbox profile live here too. Neither
    /// becomes an event: they change rarely, this mapper cannot tell a change
    /// from a repeat, and a note per turn saying the policy is what it was
    /// last turn is noise a board would have to filter.
    private static func turnContext(_ payload: CodexJSON, into emitter: inout Emitter) {
        var patch = SessionIdentityPatch()
        patch.cwd = payload["cwd"]?.string
        patch.model = payload["model"]?.string
        guard !patch.isEmpty else { return }
        emitter.add(.identityUpdated(patch))
    }

    // MARK: - Response items

    private static func responseItem(_ payload: CodexJSON, into emitter: inout Emitter) {
        switch payload["type"]?.string {
        case "message":
            message(payload, into: &emitter)
        case "reasoning":
            emitter.add(.thinking)
        case "function_call":
            let raw = payload["arguments"]?.string
            toolCallStarted(
                payload,
                name: payload["name"]?.string,
                arguments: parse(raw) ?? payload["arguments"],
                raw: raw,
                into: &emitter
            )
        case "custom_tool_call":
            let raw = payload["input"]?.string
            toolCallStarted(
                payload,
                name: payload["name"]?.string,
                arguments: parse(raw) ?? payload["input"],
                raw: raw,
                into: &emitter
            )
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            toolCallFinished(payload, into: &emitter)
        case "web_search_call":
            let action = payload["action"]
            let target = action?.firstString("query", "url")
                ?? payload["query"]?.string
                ?? action?["queries"]?.array?.first?.string
            oneShotCall(payload, name: "web_search", kind: .web, target: target, into: &emitter)
        case "tool_search_call":
            // Paired with `tool_search_output`, so only the open half here.
            toolCallStarted(
                payload,
                name: "tool_search",
                arguments: payload,
                raw: nil,
                into: &emitter
            )
        case "image_generation_call":
            oneShotCall(
                payload,
                name: "image_generation",
                kind: .other,
                target: payload["prompt"]?.string.map { EventText.preview($0, max: previewLimit) },
                into: &emitter
            )
        default:
            break
        }
    }

    /// A message the model sent or received.
    ///
    /// Only the assistant's half becomes an event. `developer` messages are
    /// the harness talking to itself — instructions, app context, multi-agent
    /// preambles — and `user` messages are covered by
    /// `event_msg.user_message`; see the type's dedupe table.
    private static func message(_ payload: CodexJSON, into emitter: inout Emitter) {
        guard payload["role"]?.string == "assistant" else { return }
        let text = payload["content"]?.joinedText ?? ""
        guard !text.isEmpty else { return }
        emitter.add(.assistantText(preview: EventText.preview(text, max: previewLimit)))
        if let body = body(text) {
            emitter.add(.textBody(role: .assistant, text: body, toolCallID: nil))
        }
    }

    private static func toolCallStarted(
        _ payload: CodexJSON,
        name: String?,
        arguments: CodexJSON?,
        raw: String?,
        into emitter: inout Emitter
    ) {
        let name = name ?? "tool"
        guard let id = payload.firstString("call_id", "id") else { return }
        let kind = CodexToolCall.kind(for: name)
        let target = CodexToolCall.target(kind: kind, arguments: arguments, raw: raw)
        emitter.add(
            .toolCallStarted(id: id, name: name, kind: kind, target: target.map(shorten))
        )
    }

    private static func toolCallFinished(_ payload: CodexJSON, into emitter: inout Emitter) {
        guard let id = payload.firstString("call_id", "id") else { return }
        let output = payload["output"]
        emitter.add(
            .toolCallFinished(
                id: id,
                isError: CodexToolCall.isError(output: output, status: payload["status"]?.string)
            )
        )
        if let body = body(CodexToolCall.outputText(output)) {
            emitter.add(.textBody(role: .toolResult, text: body, toolCallID: id))
        }
    }

    /// A call the rollout records as a single completed item — a web search, a
    /// generated image — with no separate output record to close it.
    private static func oneShotCall(
        _ payload: CodexJSON,
        name: String,
        kind: ToolKind,
        target: String?,
        into emitter: inout Emitter
    ) {
        guard let id = payload.firstString("call_id", "id") else { return }
        emitter.add(.toolCallStarted(id: id, name: name, kind: kind, target: target.map(shorten)))
        emitter.add(
            .toolCallFinished(id: id, isError: payload["status"]?.string == "failed")
        )
    }

    // MARK: - Event messages

    private static func eventMessage(
        _ payload: CodexJSON,
        session: SessionKey,
        into emitter: inout Emitter
    ) {
        switch payload["type"]?.string {
        case "user_message":
            let text = payload["message"]?.string ?? ""
            guard !text.isEmpty else { return }
            emitter.add(.userPrompt(preview: EventText.preview(text, max: previewLimit)))
            if let body = body(text) {
                emitter.add(.textBody(role: .user, text: body, toolCallID: nil))
            }
        case "agent_reasoning":
            emitter.add(.thinking)
        case "task_started":
            emitter.add(.turnStarted)
        case "task_complete":
            emitter.add(.turnEnded(reason: .complete))
        case "turn_aborted":
            emitter.add(.turnEnded(reason: .aborted))
        case "error":
            // Not a turn ending. Codex retries after most of these, and the
            // turn closes later with its own `task_complete` or
            // `turn_aborted`; ending it here would strand the row as finished
            // while the model is still working.
            let message = payload["message"]?.string ?? "unspecified"
            emitter.add(.note("error: \(EventText.preview(message, max: 160))"))
        case "token_count":
            tokenCount(payload, into: &emitter)
        case "guardian_assessment":
            guardian(payload, into: &emitter)
        case "sub_agent_activity":
            subAgent(payload, session: session, into: &emitter)
        case "collab_agent_spawn_end":
            collabSpawn(payload, session: session, into: &emitter)
        case "thread_name_updated":
            guard let name = payload.firstString("thread_name", "name", "title") else { return }
            emitter.add(
                .identityUpdated(SessionIdentityPatch(title: EventText.preview(name, max: 120)))
            )
        case "context_compacted":
            emitter.add(.compaction)
        case "exec_command_end":
            expand(
                payload,
                name: "shell",
                kind: .shell,
                target: CodexToolCall.commandLine(payload),
                isError: CodexToolCall.isError(output: payload, status: payload["status"]?.string),
                into: &emitter
            )
        case "patch_apply_end":
            expand(
                payload,
                name: "apply_patch",
                kind: .fileWrite,
                target: patchedPath(payload),
                isError: CodexToolCall.isError(output: payload, status: payload["status"]?.string),
                into: &emitter
            )
        case "web_search_end":
            expand(
                payload,
                name: "web_search",
                kind: .web,
                target: payload["query"]?.string ?? payload["action"]?.firstString("url", "query"),
                isError: false,
                into: &emitter
            )
        case "mcp_tool_call_end":
            mcpCall(payload, into: &emitter)
        case "image_generation_end":
            expand(
                payload,
                name: "image_generation",
                kind: .other,
                target: nil,
                isError: CodexToolCall.isError(output: payload, status: payload["status"]?.string),
                into: &emitter
            )
        default:
            // `thread_settings_applied`, `item_completed`, `thread_rolled_back`,
            // `agent_message` (see the dedupe table), and everything a later
            // Codex adds.
            break
        }
    }

    /// A `token_count` event: the step's token accounting, how full the
    /// context window is, and whatever the response's rate-limit headers said.
    ///
    /// The three are independent. Codex emits a `token_count` carrying only
    /// `rate_limits` when a request was refused before it billed anything, so
    /// each half is read on its own rather than behind the other's guard.
    private static func tokenCount(_ payload: CodexJSON, into emitter: inout Emitter) {
        if let info = payload["info"] { tokens(info, into: &emitter) }
        rateLimits(payload, into: &emitter)
    }

    /// Token accounting for one billed step, and the window it filled.
    ///
    /// `last_token_usage` is the delta for the step just billed and
    /// `total_token_usage` the running sum; the reducer sums what it is given,
    /// so handing it the totals would bill every step again from the start of
    /// the session. A record without `last_token_usage` is skipped rather than
    /// approximated from the totals — that would need memory of the previous
    /// record, which this mapper does not have.
    ///
    /// `input_tokens` is reported as Codex reports it, cached tokens included.
    /// Splitting it would be an accounting opinion, and the cached count
    /// travels alongside for a caller that holds a different one.
    ///
    /// That same `input_tokens` is the context level, for exactly the reason it
    /// is not split: it is the whole prompt the model was handed, which is what
    /// occupies the window. `output_tokens` is deliberately not added — it
    /// lands in the *next* call's input. The denominator is
    /// `info.model_context_window`, which Codex writes down itself, so the
    /// reading is ``ContextUsage/Source/measured`` and needs no model table.
    private static func tokens(_ info: CodexJSON, into emitter: inout Emitter) {
        guard let last = info["last_token_usage"] else { return }
        let input = last["input_tokens"]?.int ?? 0
        let output = last["output_tokens"]?.int ?? 0
        let cached = last["cached_input_tokens"]?.int ?? 0
        guard input != 0 || output != 0 || cached != 0 else { return }
        emitter.add(
            .usage(model: nil, inputTokens: input, outputTokens: output, cachedTokens: cached)
        )
        guard input > 0 else { return }
        emitter.add(
            .contextUsage(
                used: input,
                window: info["model_context_window"]?.int,
                cached: cached,
                source: .measured
            )
        )
    }

    /// The plan window the request was billed against.
    ///
    /// Only `primary` becomes an event. Codex reports a `secondary` window too
    /// — the weekly allowance beside the five-hourly one — and a row that shows
    /// two percentages without room to say which is which is worse than one
    /// that shows the limit a person is about to hit.
    ///
    /// `resets_at` is an instant on current Codex and `resets_in_seconds` a
    /// duration on older ones; both are accepted, and the duration is resolved
    /// against the *record's* timestamp rather than the clock, so a rollout
    /// replayed at cold start does not claim its limits reset an hour from now.
    private static func rateLimits(_ payload: CodexJSON, into emitter: inout Emitter) {
        guard let limits = payload["rate_limits"] ?? payload["info"]?["rate_limits"],
              let primary = limits["primary"],
              let usedPercent = primary["used_percent"]?.double
        else { return }
        emitter.add(
            .quota(
                usedPercent: usedPercent,
                resetsAt: resetDate(primary, recordedAt: emitter.timestamp),
                plan: limits.firstString("plan_type", "plan")
                    ?? payload.firstString("plan_type", "plan")
            )
        )
    }

    private static func resetDate(_ window: CodexJSON, recordedAt: Date) -> Date? {
        if let text = window["resets_at"]?.string, let date = SessionParsing.parseISO(text) {
            return date
        }
        if let seconds = window["resets_in_seconds"]?.int {
            return recordedAt.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
    }

    /// Codex's approval channel.
    ///
    /// One `guardian_assessment` id spans the whole decision: `in_progress`
    /// when the harness blocks, then the same id again carrying the verdict.
    /// `timed_out` counts as a refusal — the tool did not run — and so does
    /// any status a later Codex adds, because the one wrong answer here is
    /// telling a board a session was unblocked when it is still waiting.
    private static func guardian(_ payload: CodexJSON, into emitter: inout Emitter) {
        guard let id = payload["id"]?.string, let status = payload["status"]?.string else { return }
        if status == "in_progress" {
            emitter.add(.permissionRequested(id: id, tool: payload["action"]?["type"]?.string))
        } else {
            emitter.add(.permissionResolved(id: id, allowed: status == "approved"))
        }
    }

    /// A child thread starting, ending, or doing something in between.
    ///
    /// The child is a real session with a rollout of its own, keyed by
    /// `agent_thread_id`, and discovery finds it independently; this is the
    /// parent's side of the edge, which is what carries the `toolUseID`.
    ///
    /// Only `started` opens the child and only an explicitly terminal `kind`
    /// closes it. `interrupted` looks terminal and is not: the corpus has
    /// `started → interacted → interrupted → interacted` on one thread, so
    /// treating it as an ending would show a child as finished while it is
    /// still answering.
    private static func subAgent(
        _ payload: CodexJSON,
        session: SessionKey,
        into emitter: inout Emitter
    ) {
        guard let threadID = payload.firstString("agent_thread_id", "thread_id") else { return }
        let child = SessionKey(harness: session.harness, sessionID: threadID)
        let name = payload["agent_path"]?.string.map(lastPathComponent)
        switch payload["kind"]?.string {
        case "started":
            emitter.add(
                .subagentStarted(
                    child: child,
                    agentType: name,
                    toolUseID: payload.firstString("event_id", "call_id")
                )
            )
        case "ended", "finished", "completed", "closed", "stopped", "failed":
            emitter.add(.subagentFinished(child: child))
        case let kind?:
            emitter.add(.note("sub-agent \(kind): \(name ?? threadID)"))
        case nil:
            break
        }
    }

    /// The other spawn record, for the collaboration surface.
    ///
    /// Best effort by design: no rollout on the corpus this was built against
    /// carried one with a thread id, so it is mapped by the field names the
    /// neighbouring records use and does nothing at all when they are absent.
    private static func collabSpawn(
        _ payload: CodexJSON,
        session: SessionKey,
        into emitter: inout Emitter
    ) {
        guard let threadID = payload.firstString("agent_thread_id", "thread_id", "child_thread_id")
        else { return }
        emitter.add(
            .subagentStarted(
                child: SessionKey(harness: session.harness, sessionID: threadID),
                agentType: payload["agent_path"]?.string.map(lastPathComponent),
                toolUseID: payload.firstString("call_id", "event_id")
            )
        )
    }

    private static func mcpCall(_ payload: CodexJSON, into emitter: inout Emitter) {
        let invocation = payload["invocation"]
        let server = invocation?["server"]?.string ?? "mcp"
        let tool = invocation?["tool"]?.string
        let result = payload["result"]
        let failed = result?["Err"] != nil || CodexToolCall.isError(output: result?["Ok"])
        expand(
            payload,
            name: tool.map { "\(server).\($0)" } ?? server,
            kind: .mcp,
            target: server,
            isError: failed,
            into: &emitter
        )
    }

    /// Expands a `*_end` event into the pair of events the work it describes
    /// never got, unless a `response_item` already produced them.
    private static func expand(
        _ payload: CodexJSON,
        name: String,
        kind: ToolKind,
        target: String?,
        isError: Bool,
        into emitter: inout Emitter
    ) {
        guard let id = payload["call_id"]?.string, !isResponseItemCallID(id) else { return }
        emitter.add(.toolCallStarted(id: id, name: name, kind: kind, target: target.map(shorten)))
        emitter.add(.toolCallFinished(id: id, isError: isError))
    }

    /// The file a `patch_apply_end` touched.
    ///
    /// `changes` is keyed by absolute path; JSON decoding does not preserve
    /// its order, so the paths are sorted and the first is reported. A patch
    /// touching one file — the common case — is unaffected, and for a patch
    /// touching four, a status row has room for one anyway.
    private static func patchedPath(_ payload: CodexJSON) -> String? {
        if let changes = payload["changes"]?.object, let first = changes.keys.sorted().first {
            return first
        }
        return payload["files"]?.array?.compactMap(\.string).sorted().first
    }

    // MARK: - Text

    /// A tool target, short enough for a status row.
    private static func shorten(_ target: String) -> String {
        EventText.preview(target, max: previewLimit)
    }

    /// A full-text body, capped at ``AgentEventKind/textBodyLimit`` bytes, or
    /// `nil` when there is nothing to carry.
    ///
    /// Cut on a scalar boundary rather than a byte one: a body sliced through
    /// a multi-byte character reaches a full-text index as mojibake, and a
    /// tool that dumps a UTF-8 log is exactly the one that overruns the cap.
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

    private static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Parses an argument string that is itself JSON, which is how
    /// `function_call.arguments` always arrives and how `custom_tool_call.input`
    /// sometimes does.
    private static func parse(_ raw: String?) -> CodexJSON? {
        guard let raw, !raw.isEmpty,
              let value = try? JSONDecoder().decode(CodexJSON.self, from: Data(raw.utf8)),
              value.object != nil
        else { return nil }
        return value
    }

    /// Stamps every event with the session, the two clocks, and nothing else —
    /// ``JSONLTailer`` owns `sequence` and fills in ``AgentEvent/raw``.
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
