import AgentSessionKit
import Foundation

/// Turns one message out of a Cursor `store.db` into ``AgentEvent``s.
///
/// Pure, stateless, and total: same message in, same events out, no clock of
/// its own beyond the `now` it is handed, and never a throw. A message it
/// cannot make sense of yields `[]`.
///
/// It sets neither ``AgentEvent/sequence`` nor ``AgentEvent/raw``; the tailer
/// owns both, because it is the thing that knows the order blobs arrived in.
///
/// ## Message → event
///
/// | Message | Events |
/// | --- | --- |
/// | any part with `providerOptions.cursor.modelName` | `identityUpdated(model:)` |
/// | `role: user`, text | `userPrompt(preview:)` when this mapper owns it, and `textBody(.user, …)` |
/// | `role: assistant`, `text` part | `assistantText(preview:)`, `textBody(.assistant, …)` |
/// | any `reasoning` part | `thinking` |
/// | `tool-call` part | `toolCallStarted(id:name:kind:target:)` |
/// | `tool-result` part | `toolCallFinished(id:isError:)`, `textBody(.toolResult, …, toolCallID:)` |
/// | `role: system` | *nothing* |
/// | any other part type | *nothing* |
///
/// ## Judgement calls
///
/// - **The prompt wrapper comes off.** A user message's text is a
///   `<timestamp>` element followed by a `<user_query>` wrapper around what a
///   person typed; ``CursorPromptText`` unwraps it, and a preview of the raw
///   text would show a board the word "timestamp" for every session.
/// - **Who owns `userPrompt` is the caller's decision.** The thin transcript
///   under `~/.cursor/projects` records the same prompt, and the reducer
///   counts a turn per ``AgentEventKind/userPrompt(preview:)``, so exactly one
///   of the two sources may emit it. ``CursorSessionTailer`` gives it to the
///   thin transcript when there is one and to the store when there is not.
///   `textBody(.user, …)` is always the store's: it is the full text, and the
///   thin transcript truncates.
/// - **Reasoning text never leaves the store.** A `reasoning` part becomes a
///   bare ``AgentEventKind/thinking``. The board renders a state, not a
///   model's private scratch work, and the same choice is made in every other
///   adapter here.
/// - **A system message is dropped whole.** Cursor stores the assembled system
///   prompt — rules files, the workspace layout, a person's global
///   instructions — and none of that is a fact about a session's *activity*.
/// - **`timestamp` is the message's own, then the header, then `now`.** The
///   protobuf nodes carry a millisecond field, but every node in a
///   conversation carries the same value, so it dates the conversation rather
///   than the turn and is deliberately not used here.
public enum CursorMessageMapper: Sendable {
    /// Characters kept in a `userPrompt` or `assistantText` preview.
    public static let previewLimit = 200

    /// Maps one message.
    ///
    /// - Parameters:
    ///   - message: A message decoded by ``CursorStoreReader/decode(_:)``.
    ///   - session: The key events are attributed to.
    ///   - now: The observation clock. Becomes ``AgentEvent/observedAt`` on
    ///     every event, and ``AgentEvent/timestamp`` on a message that carries
    ///     no time of its own.
    ///   - emitsUserPrompt: Whether this mapper owns
    ///     ``AgentEventKind/userPrompt(preview:)``. `false` when a thin
    ///     transcript is emitting it, which is the common case for a session a
    ///     `cursor-agent` CLI drove.
    public static func events(
        from message: CursorMessage,
        session: SessionKey,
        now: Date,
        emitsUserPrompt: Bool = true
    ) -> [AgentEvent] {
        var kinds: [AgentEventKind] = []

        if let model = message.model {
            kinds.append(.identityUpdated(SessionIdentityPatch(model: model)))
        }

        switch message.role {
        case "system":
            // Cursor keeps the assembled system prompt in the same graph as
            // the conversation. It says nothing about what the session is
            // doing, and it is the most personal thing in the store.
            kinds.removeAll()

        case "user":
            kinds.append(contentsOf: userKinds(message, emitsUserPrompt: emitsUserPrompt))

        default:
            kinds.append(contentsOf: assistantKinds(message))
        }

        guard !kinds.isEmpty else { return [] }
        let timestamp = message.timestamp ?? now
        return kinds.map {
            AgentEvent(session: session, timestamp: timestamp, observedAt: now, kind: $0)
        }
    }

    // MARK: - Roles

    private static func userKinds(_ message: CursorMessage, emitsUserPrompt: Bool) -> [AgentEventKind] {
        var kinds: [AgentEventKind] = []
        let text = CursorPromptText.body(message.plainText)
        if !text.isEmpty {
            if emitsUserPrompt {
                kinds.append(.userPrompt(preview: EventText.preview(text, max: previewLimit)))
            }
            kinds.append(.textBody(role: .user, text: bounded(text), toolCallID: nil))
        }
        // Some vintages return a tool's output on the user turn that follows
        // the call. Pairing it with the call that opened it matters more than
        // which role it arrived under.
        kinds.append(contentsOf: partKinds(message.parts, assistantProse: false))
        return kinds
    }

    private static func assistantKinds(_ message: CursorMessage) -> [AgentEventKind] {
        partKinds(message.parts, assistantProse: true)
    }

    private static func partKinds(
        _ parts: [CursorContentPart],
        assistantProse: Bool
    ) -> [AgentEventKind] {
        var kinds: [AgentEventKind] = []
        for part in parts {
            switch part {
            case let .text(text):
                guard assistantProse else { continue }
                guard !EventText.collapseWhitespace(text).isEmpty else { continue }
                kinds.append(.assistantText(preview: EventText.preview(text, max: previewLimit)))
                kinds.append(.textBody(role: .assistant, text: bounded(text), toolCallID: nil))

            case .reasoning:
                kinds.append(.thinking)

            case let .toolCall(id, name, arguments):
                let mapping = CursorToolMapping.resolve(name: name, arguments: arguments)
                kinds.append(.toolCallStarted(
                    id: id, name: name, kind: mapping.kind, target: mapping.target
                ))

            case let .toolResult(id, isError, text):
                kinds.append(.toolCallFinished(id: id, isError: isError))
                guard !text.isEmpty else { continue }
                kinds.append(.textBody(role: .toolResult, text: bounded(text), toolCallID: id))

            case .other:
                continue
            }
        }
        return kinds
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

/// The normalised activity behind a Cursor tool name, and what the call is
/// aimed at.
///
/// The names come from `cursor-agent` and from the IDE agent, which do not
/// use the same set, so both are covered and neither is required. Anything
/// unrecognised is ``ToolKind/other`` rather than a guess: a wrong kind
/// colours a board row wrongly and is harder to notice than a grey one.
///
/// Two entries deliberately match ``ClaudeToolMapping`` rather than the
/// literal reading of Cursor's own naming: a glob is a ``ToolKind/search``
/// (Claude's `Glob` is), and `todo_write` is ``ToolKind/plan`` (Claude's
/// `TodoWrite` is). The whole point of the kind axis is that one activity is
/// one column whatever the harness called it.
public enum CursorToolMapping: Sendable {
    /// A resolved tool call: what it does, and what it does it to.
    public struct Resolution: Hashable, Sendable {
        /// The normalised activity.
        public let kind: ToolKind
        /// The path, command, url, query, or server the call is aimed at,
        /// already truncated for display.
        public let target: String?

        /// Creates a resolution.
        public init(kind: ToolKind, target: String?) {
            self.kind = kind
            self.target = target
        }
    }

    /// Characters kept in a tool call's `target`.
    public static let targetLimit = 120

    /// The prefix Cursor gives every MCP tool: `mcp_<server>_<tool>`.
    public static let mcpPrefix = "mcp_"

    /// Resolves one tool call.
    ///
    /// - Parameters:
    ///   - name: The raw `toolName` from the `tool-call` part.
    ///   - arguments: The whitelisted subset of the call's arguments — see
    ///     ``CursorMessage/toolArgumentKeys``.
    public static func resolve(name: String, arguments: [String: String]) -> Resolution {
        let lowered = name.lowercased()
        if lowered.hasPrefix(mcpPrefix) {
            return Resolution(kind: .mcp, target: server(inMCPName: lowered))
        }
        switch lowered {
        case "shell", "run_terminal_cmd", "run_terminal_command", "terminal", "bash",
             "execute", "execute_command", "run_command":
            return Resolution(kind: .shell, target: display(arguments["command"] ?? arguments["cmd"]
                ?? arguments["script"]))

        case "read_file", "read", "read_files", "list_dir", "list_directory", "ls",
             "notebook_read", "read_notebook":
            return Resolution(kind: .fileRead, target: displayPath(arguments))

        case "grep", "grep_search", "codebase_search", "search", "semantic_search",
             "file_search", "glob", "glob_file_search", "ripgrep":
            return Resolution(kind: .search, target: display(
                arguments["query"] ?? arguments["pattern"] ?? arguments["glob_pattern"]
                    ?? arguments["search_term"] ?? arguments["regex"] ?? arguments["path"]
            ))

        case "edit_file", "write", "write_file", "create_file", "apply_patch", "multi_edit",
             "multiedit", "search_replace", "str_replace", "delete_file", "remove_file",
             "notebook_edit":
            return Resolution(kind: .fileWrite, target: displayPath(arguments))

        case "web_search", "fetch", "web_fetch", "fetch_url", "read_web_page", "browser":
            return Resolution(kind: .web, target: display(arguments["url"] ?? arguments["uri"]
                ?? arguments["query"] ?? arguments["search_term"]))

        case "task", "subagent", "spawn_agent", "explore_subagent", "launch_agent", "agent":
            return Resolution(kind: .subagent, target: display(
                arguments["description"] ?? arguments["agent"] ?? arguments["subagent_type"]
                    ?? arguments["agentType"]
            ))

        case "todo_write", "todowrite", "update_plan", "create_plan", "plan":
            return Resolution(kind: .plan, target: display(arguments["description"]))

        default:
            return Resolution(kind: .other, target: display(
                arguments["description"] ?? arguments["explanation"] ?? displayPath(arguments)
            ))
        }
    }

    /// The server half of `mcp_<server>_<tool>`, or `nil` when the rest of
    /// the name is empty.
    ///
    /// Cursor's separator is a single underscore and a server name may itself
    /// contain one, so this is the first segment and not a parse — the same
    /// honest guess `mcp_github_create_issue` forces on anybody.
    static func server(inMCPName name: String) -> String? {
        let body = name.dropFirst(mcpPrefix.count)
        guard !body.isEmpty else { return nil }
        guard let separator = body.firstIndex(of: "_") else { return String(body) }
        let server = body[body.startIndex..<separator]
        return server.isEmpty ? String(body) : String(server)
    }

    private static func displayPath(_ arguments: [String: String]) -> String? {
        display(
            arguments["target_file"] ?? arguments["targetFile"] ?? arguments["file_path"]
                ?? arguments["filePath"] ?? arguments["path"] ?? arguments["file"]
                ?? arguments["relative_workspace_path"] ?? arguments["dir_path"]
                ?? arguments["directory"] ?? arguments["notebook_path"]
        )
    }

    private static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let preview = EventText.preview(value, max: targetLimit)
        return preview.isEmpty ? nil : preview
    }
}
