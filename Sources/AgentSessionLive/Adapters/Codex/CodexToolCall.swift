import Foundation

/// Reading a Codex tool call: what activity it is, what it is aimed at, and
/// whether it failed.
///
/// Split out of ``CodexRecordMapper`` because it is the part with real
/// judgement in it. Codex names the same activity three ways depending on
/// which surface produced the rollout — the CLI calls a command `shell`, the
/// desktop app wraps everything in a JavaScript `exec` sandbox, and a
/// sub-agent spawn is a plain function call — and every one of those has to
/// land on the same ``ToolKind`` or a board groups one activity into three
/// columns.
enum CodexToolCall {
    /// The normalised activity behind a Codex tool name.
    ///
    /// Only names actually observed in rollouts are mapped. Anything else is
    /// ``ToolKind/other``, which is the honest answer: a guessed kind puts a
    /// row in the wrong column and a wrong column is worse than a generic one.
    static func kind(for name: String) -> ToolKind {
        // An MCP tool reaches the model as `mcp__<server>__<tool>`, and the
        // synthetic name this adapter builds for a `mcp_tool_call_end` is
        // `<server>.<tool>`. Both are checked before the exact-name table so
        // that an MCP server called `search` is not filed as a grep.
        if name.hasPrefix("mcp__") { return .mcp }

        switch name {
        case "shell", "shell_command", "exec_command", "local_shell", "exec", "container.exec":
            return .shell
        case "apply_patch":
            return .fileWrite
        case "read_file", "list_dir", "view":
            return .fileRead
        case "grep", "rg", "search", "tool_search":
            return .search
        case "web_search":
            return .web
        case "spawn_agent":
            return .subagent
        case "wait_agent", "list_agents", "interrupt_agent":
            return .other
        default:
            return .other
        }
    }

    /// What a call is aimed at: the command, the file, the query, the server.
    ///
    /// `arguments` is the parsed argument object when the record carried
    /// parseable JSON, and `raw` the verbatim string — a `function_call`
    /// carries JSON in `arguments`, a `custom_tool_call` carries JavaScript in
    /// `input`, and only the second needs scanning.
    ///
    /// Returns `nil` rather than a placeholder when nothing usable is there.
    static func target(
        kind: ToolKind,
        arguments: CodexJSON?,
        raw: String?
    ) -> String? {
        switch kind {
        case .shell:
            if let command = commandLine(arguments) { return command }
            if let raw, let command = sandboxCommand(in: raw) { return command }
            return raw.flatMap(firstMeaningfulLine)
        case .fileWrite:
            if let patch = arguments?.firstString("input", "patch", "diff"),
               let path = patchTarget(in: patch) {
                return path
            }
            if let raw, let path = patchTarget(in: raw) { return path }
            return arguments?.firstString("path", "file_path", "target_file")
        case .fileRead:
            return arguments?.firstString("path", "file_path", "target_file", "dir", "directory")
        case .search:
            return arguments?.firstString("pattern", "query", "regex", "path")
        case .web:
            return arguments?.firstString("query", "url", "search_term")
        case .subagent:
            return arguments?.firstString("prompt", "task", "role", "agent_path", "name")
        case .mcp, .plan, .other:
            return nil
        }
    }

    /// The shell command inside a tool call's arguments, however this vintage
    /// spelled it.
    ///
    /// `command` is an argv array in the CLI (`["bash", "-lc", "…"]`), `cmd` a
    /// single string in the desktop sandbox. Joining argv with spaces is a
    /// display decision, not a quoting one: this string is shown, never run.
    static func commandLine(_ arguments: CodexJSON?) -> String? {
        guard let arguments else { return nil }
        if let argv = arguments["command"]?.array {
            let parts = argv.compactMap(\.string)
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return arguments.firstString("command", "cmd", "script")
    }

    /// The command a desktop `exec` script hands to the sandbox.
    ///
    /// The desktop app does not record a shell call as a tool call of its own.
    /// It records a JavaScript program, and the command is a string literal
    /// inside it: `await tools.exec_command({cmd: "swift build"})`. Scanning
    /// for it is a heuristic and is treated as one — a miss falls back to the
    /// first line of the script, never to a fabricated command.
    static func sandboxCommand(in script: String) -> String? {
        let scope: Substring
        if let call = script.range(of: "exec_command") {
            scope = script[call.upperBound...]
        } else {
            scope = script[script.startIndex...]
        }
        return quotedValue(forKey: "cmd", in: scope)
    }

    /// The first path named by a patch header.
    ///
    /// `apply_patch` takes the OpenAI patch envelope, whose file headers are
    /// `*** Add File: <path>`, `*** Update File: <path>`,
    /// `*** Delete File: <path>`, and `*** Move to: <path>`. A patch touching
    /// four files reports the first, which is what a status row has space for.
    static func patchTarget(in patch: String) -> String? {
        let markers = ["*** Update File:", "*** Add File:", "*** Delete File:", "*** Move to:"]
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in markers where trimmed.hasPrefix(marker) {
                let path = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// Whether a tool result says the call failed.
    ///
    /// Codex records failure four ways and no rollout uses more than two of
    /// them: an `exit_code` beside the output (CLI shell calls), a
    /// `metadata.exit_code` inside a JSON output string (the same, wrapped), a
    /// `success` flag (`patch_apply_end`), and an `isError` flag (MCP results).
    /// Nothing said is *not* an error — a tool that produced output and no
    /// verdict succeeded.
    static func isError(output: CodexJSON?, status: String? = nil) -> Bool {
        if let status, ["failed", "error", "incomplete", "denied"].contains(status.lowercased()) {
            return true
        }
        guard let output else { return false }
        if verdict(in: output) == true { return true }
        // The CLI writes the whole result as a JSON *string*, so the flags are
        // one parse deeper than they look.
        if case let .string(text) = output,
           let nested = try? JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8)),
           verdict(in: nested) == true {
            return true
        }
        return false
    }

    /// `true` when this object carries a failure flag, `false` when it carries
    /// a success flag, `nil` when it says nothing either way.
    private static func verdict(in value: CodexJSON) -> Bool? {
        if let code = value["exit_code"]?.int { return code != 0 }
        if let code = value["metadata"]?["exit_code"]?.int { return code != 0 }
        if let success = value["success"]?.bool { return !success }
        if let isError = value["isError"]?.bool { return isError }
        return nil
    }

    /// The text of a tool result, unwrapped from whichever envelope it came in.
    ///
    /// Three shapes: a plain string (older CLI), a JSON string whose `output`
    /// member is the real text (current CLI), and an array of
    /// `{"type": "input_text", "text": …}` parts (desktop). Unwrapping matters
    /// because the second shape puts a wall of JSON in front of the one line a
    /// person wanted to read.
    static func outputText(_ output: CodexJSON?) -> String {
        guard let output else { return "" }
        if case let .string(text) = output {
            if let nested = try? JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8)),
               let inner = nested["output"]?.string {
                return inner
            }
            return text
        }
        return output.joinedText
    }

    // MARK: - Scanning

    /// The first non-empty line of `text`, capped so a minified script does
    /// not become the whole target.
    private static func firstMeaningfulLine(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(160)) }
        }
        return nil
    }

    /// The string literal assigned to `key` somewhere in `text`.
    ///
    /// A deliberately small scanner rather than a JavaScript parse: it accepts
    /// `cmd:`, `"cmd":`, and `'cmd':`, accepts all three JavaScript quote
    /// characters, and understands backslash escapes well enough not to stop
    /// at an escaped quote. Anything it does not understand yields `nil`,
    /// which the caller treats as "no target", never as an empty command.
    static func quotedValue(forKey key: String, in text: Substring) -> String? {
        var searchStart = text.startIndex
        while let match = text.range(of: key, range: searchStart..<text.endIndex) {
            searchStart = match.upperBound
            var index = match.upperBound
            if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                index = text.index(after: index)
            }
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == ":" else { continue }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            let quote = text[index]
            guard quote == "\"" || quote == "'" || quote == "`" else { continue }
            index = text.index(after: index)

            var value = ""
            var escaped = false
            while index < text.endIndex {
                let character = text[index]
                if escaped {
                    switch character {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": value.append("\r")
                    default: value.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    return value.isEmpty ? nil : value
                } else {
                    value.append(character)
                }
                index = text.index(after: index)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
