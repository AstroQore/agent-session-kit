import AgentSessionKit
import Foundation

/// Turns one `steps` row — and what that row looked like last time — into
/// events.
///
/// ## Why a row needs a "last time"
///
/// Every other harness in this package writes an append-only log, so a mapper
/// is a pure function of one record. AntiGravity is not: a tool call is a
/// single row whose `status` column is *rewritten* as the call proceeds, and
/// the same is true of a model reply. `toolCallStarted` and `toolCallFinished`
/// are therefore not two records, they are the same record read twice, and the
/// only way to emit each exactly once is to compare against the last status
/// seen.
///
/// That comparison state is ``RowState``, and it is what
/// ``AntigravityConversationTailer`` keeps in memory between polls.
///
/// ## What is deliberately not claimed
///
/// - **Output tokens.** The payload records prompt tokens (`5.9.1` / `5.11`)
///   and nothing this decoder trusts as a completion count, so ``usage`` goes
///   out with `outputTokens: 0` rather than an invented number. A host summing
///   AntiGravity output tokens will get zero, which is at least honestly zero.
/// - **The model.** `gen_metadata` knows it; a step row does not. It is left
///   `nil` here and seeded by discovery instead.
/// - **A child's session id.** A row says it *has* a subtrajectory, never
///   which conversation that is. The parent → child edge comes from
///   `conversation_summaries.parent_conversation_id` through
///   ``AntigravityConversationRegistry``, so no event here invents a key.
public enum AntigravityStepMapper {
    /// What a row looked like the last time it was read.
    ///
    /// `openedToolCall` and `openedPermission` are not derivable from the
    /// status alone: they record that *this tailer* emitted the opening event,
    /// which is what stops a second one going out and what makes the closing
    /// one match.
    public struct RowState: Hashable, Sendable {
        /// The status last seen in the row.
        public var status: AntigravityStepStatus
        /// The id a ``AgentEventKind/toolCallStarted(id:name:kind:target:)``
        /// went out under, when one did.
        public var toolCallID: String?
        /// A permission prompt is open for this row.
        public var openedPermission: Bool

        /// Creates a state.
        public init(
            status: AntigravityStepStatus,
            toolCallID: String? = nil,
            openedPermission: Bool = false
        ) {
            self.status = status
            self.toolCallID = toolCallID
            self.openedPermission = openedPermission
        }

        /// `true` when a tool call was opened and not yet closed.
        public var openedToolCall: Bool { toolCallID != nil }
    }

    /// What one row produced: the events, and the state to remember for the
    /// next poll.
    public struct Mapped: Sendable {
        /// Events, in the order they should be delivered.
        public let events: [AgentEvent]
        /// The row's state after this read.
        public let state: RowState

        /// Creates a result.
        public init(events: [AgentEvent], state: RowState) {
            self.events = events
            self.state = state
        }
    }

    /// The state to adopt for a row that was already consumed before a
    /// restart, without re-emitting anything for it.
    ///
    /// A row that is still open is assumed to have had its opening event
    /// emitted by the previous run, so its close will still be paired. A row
    /// that is already terminal is adopted silently.
    public static func resumedState(for row: AntigravityConversationReader.StepRow) -> RowState {
        let status = row.status
        let blocking = isBlocking(row)
        return RowState(
            status: status,
            toolCallID: row.stepType?.isTool == true && status.isOpen ? toolCallID(row) : nil,
            openedPermission: blocking
        )
    }

    /// Maps one row against what it looked like last time.
    ///
    /// `previous` is `nil` the first time a row is seen, which is the common
    /// case: a row usually arrives already `RUNNING` or already `DONE` and the
    /// mapper emits its whole arc at once.
    public static func map(
        row: AntigravityConversationReader.StepRow,
        previous: RowState?,
        session: SessionKey,
        sourcePath: String,
        now: Date
    ) -> Mapped {
        var kinds: [(kind: AgentEventKind, at: Date)] = []
        var state = RowState(status: row.status, toolCallID: previous?.toolCallID,
                             openedPermission: previous?.openedPermission ?? false)

        let payload = row.payload
        let opened = payload?.startedAt ?? transitionTime(payload, .running) ?? now
        let closed = payload?.endedAt ?? payload?.transitions.last?.at ?? opened
        let isFirstSighting = previous == nil
        let wasOpen = previous?.status.isOpen ?? false
        let becameTerminal = row.status.isTerminal && (isFirstSighting || wasOpen)

        // 1. Prompts and replies. Both are one row that fills in over time, so
        //    each state event goes out on the transition into it, never again.
        switch row.stepType {
        case .userInput where isFirstSighting:
            let text = payload?.textPreview
            kinds.append((.userPrompt(preview: EventText.preview(text ?? "")), opened))
            if let body = body(text) {
                kinds.append((.textBody(role: .user, text: body, toolCallID: nil), opened))
            }
            kinds.append((.turnStarted, opened))

        case .plannerResponse:
            if row.status.isOpen, previous?.status.isOpen != true {
                kinds.append((.thinking, opened))
            }
            if becameTerminal {
                if let text = payload?.textPreview {
                    kinds.append((.assistantText(preview: EventText.preview(text)), closed))
                    if let body = body(text) {
                        kinds.append((
                            .textBody(role: .assistant, text: body, toolCallID: nil), closed
                        ))
                    }
                } else {
                    // A planner response that only asked for a tool carries no
                    // prose at all. It is still reasoning, and saying so beats
                    // an `assistantText` with nothing in it.
                    if isFirstSighting { kinds.append((.thinking, opened)) }
                    kinds.append((.note("planner response"), closed))
                }
            }

        case .errorMessage where isFirstSighting:
            let text = payload?.textPreview.map { EventText.preview($0, max: 160) }
            kinds.append((.note(text.map { "error: \($0)" } ?? "error message"), closed))

        case .notifyUser, .systemMessage, .ephemeralMessage:
            if isFirstSighting, let text = payload?.textPreview {
                let label = row.stepType?.label ?? "message"
                kinds.append((.note("\(label): \(EventText.preview(text, max: 160))"), opened))
            }

        case .conversationHistory where isFirstSighting:
            // Prior turns replayed into the context. It is *not* a compaction
            // — nothing was summarised away — so it rides as a note rather
            // than as a case that would make a board claim otherwise.
            kinds.append((.note("conversation history"), opened))

        default:
            break
        }

        // 2. Tool calls. The id is minted once and kept in the state, so the
        //    close pairs with the open even if the payload gained a call id in
        //    between.
        if row.stepType?.isTool == true {
            if state.toolCallID == nil, !(previous?.status.isTerminal ?? false) {
                let id = toolCallID(row)
                state.toolCallID = id
                kinds.append((
                    .toolCallStarted(
                        id: id,
                        name: row.toolName,
                        kind: row.toolKind ?? .other,
                        target: target(row)
                    ),
                    opened
                ))
            }
            if becameTerminal, let id = state.toolCallID {
                kinds.append((
                    .toolCallFinished(id: id, isError: row.status == .error), closed
                ))
                state.toolCallID = nil
            }
        }

        // 3. Blocking on a person. `WAITING` is the status the harness parks a
        //    row in while it needs an answer, whatever the row's type; an
        //    `ASK_QUESTION` that has not finished is the same thing said
        //    twice.
        let blocking = isBlocking(row)
        if blocking, !(previous?.openedPermission ?? false) {
            kinds.append((
                .permissionRequested(id: permissionID(row), tool: row.stepType?.label), opened
            ))
            state.openedPermission = true
        } else if !blocking, previous?.openedPermission == true {
            kinds.append((
                .permissionResolved(id: permissionID(row), allowed: row.status != .canceled), closed
            ))
            state.openedPermission = false
        }

        // 4. Accounting. Emitted once, when the row settles — a step that is
        //    still generating has a token count that is still moving — and
        //    only for a step that names the model request it billed against.
        //    `5.11` repeats the same prompt tokens on rows that made no
        //    request of their own, and counting those would bill one prompt
        //    several times over.
        if becameTerminal, payload?.requestID != nil,
           let tokens = payload?.promptTokens, tokens > 0 {
            kinds.append((
                .usage(model: nil, inputTokens: tokens, outputTokens: 0, cachedTokens: 0), closed
            ))
        }

        let events = kinds.map { entry in
            AgentEvent(
                session: session,
                timestamp: entry.at,
                observedAt: now,
                kind: entry.kind,
                raw: RawRef(path: sourcePath, rowID: Int64(row.idx))
            )
        }
        return Mapped(events: events, state: state)
    }

    // MARK: - Turn boundaries

    /// Whether a batch of rows leaves the conversation settled, and how it
    /// ended.
    ///
    /// A conversation is between turns when nothing is still open. `FINISH` is
    /// the row AntiGravity writes when it means it, but plenty of trajectories
    /// simply stop, so "the last row is terminal and none is running" has to
    /// close a turn too or a board would show every finished session as busy.
    public static func turnEnd(rows: [AntigravityConversationReader.StepRow]) -> TurnEndReason? {
        guard let last = rows.last else { return nil }
        guard rows.allSatisfy({ $0.status.isTerminal }) else { return nil }
        if rows.contains(where: { $0.status == .error }) { return .error }
        if last.status == .canceled || last.status == .interrupted { return .aborted }
        if last.status.isFailure { return .error }
        return .complete
    }

    // MARK: - Row shapes

    /// `true` while the row is blocked on a person.
    static func isBlocking(_ row: AntigravityConversationReader.StepRow) -> Bool {
        if row.status == .waiting { return true }
        return row.stepType == .askQuestion && row.status.isOpen
    }

    /// The id a permission prompt is tracked under. Derived from the row so a
    /// resolution always matches the request that opened it.
    static func permissionID(_ row: AntigravityConversationReader.StepRow) -> String {
        "step-\(row.idx)"
    }

    /// The id a tool call is tracked under: AntiGravity's own call id when the
    /// payload carried one, otherwise the row index.
    ///
    /// Call ids are unique only within a conversation, which is exactly the
    /// scope an event id needs.
    static func toolCallID(_ row: AntigravityConversationReader.StepRow) -> String {
        guard let callID = row.payload?.toolCall?.callID, !callID.isEmpty else {
            return "step-\(row.idx)"
        }
        return callID
    }

    /// The file, command, url, or query a call is aimed at, from the tool's
    /// own arguments JSON.
    ///
    /// Only keys AntiGravity actually uses, and only a top-level string: a
    /// board wants "which file" and nothing here is going to dig for it.
    static func target(_ row: AntigravityConversationReader.StepRow) -> String? {
        if let query = row.payload?.textPreview, row.stepType == .searchWeb {
            return EventText.preview(query, max: 120)
        }
        guard let json = row.payload?.toolCall?.argsJSON,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for key in targetKeys {
            guard let value = object[key] as? String, !value.isEmpty else { continue }
            return EventText.preview(value, max: 200)
        }
        return nil
    }

    /// Argument names that carry a call's subject, most specific first.
    static let targetKeys = [
        "CommandLine", "Command", "command",
        "AbsolutePath", "TargetFile", "AbsolutePathToFile", "file_path", "path",
        "Url", "url", "Query", "query", "SearchTerm", "search_term",
        "DirectoryPath", "directory", "ServerName"
    ]

    /// The timestamp of the first transition into `status`, when the log has
    /// one.
    static func transitionTime(
        _ payload: AntigravityStepPayload?,
        _ status: AntigravityStepStatus
    ) -> Date? {
        payload?.transitions.first { $0.status == status }?.at
    }

    /// A prompt or reply, capped at ``AgentEventKind/textBodyLimit`` bytes on
    /// a character boundary.
    ///
    /// Returns `nil` for an empty string so a body event is never emitted with
    /// nothing in it.
    public static func body(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count > AgentEventKind.textBodyLimit else { return text }
        var out = ""
        var bytes = 0
        for character in text {
            let width = String(character).utf8.count
            if bytes + width > AgentEventKind.textBodyLimit { break }
            out.append(character)
            bytes += width
        }
        return out.isEmpty ? nil : out
    }
}
