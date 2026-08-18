import Foundation

/// Reading a Grok Build tool call: what it is called, what kind of work it is,
/// and what it is aimed at.
///
/// Split out of ``GrokRecordMapper`` for the same reason `CodexToolCall` is:
/// the mapping from a harness's tool vocabulary onto ``ToolKind`` is the part
/// that changes when the harness ships a new tool, and it is worth being able
/// to read it without the record plumbing around it.
///
/// ## Three sources for one answer, in order
///
/// A `tool_call` update carries the tool's identity in up to three places, and
/// which of them are populated depends on whether the tool runs locally or on
/// the model backend:
///
/// | Source | Example | Populated for |
/// | --- | --- | --- |
/// | `_meta["x.ai/tool"]` | `{"name": "web_fetch", "kind": "web_fetch", "namespace": "grok_build", "label": "Web Fetch"}` | local tools |
/// | `kind` | `"search"`, `"execute"`, `"fetch"` | backend tools, and local ones once the call updates |
/// | `title` | `"Web search:"`, `"Fetch: https://…"` | everything |
///
/// The descriptor wins where it exists because it is the harness's own
/// identifier for the tool rather than a rendering of it; `kind` is the ACP
/// vocabulary and is next; `title` is a display string and is the last resort,
/// trimmed of the trailing colon a `"Web search:"` carries.
enum GrokToolCall {
    /// The key `_meta` hangs the tool descriptor off.
    static let descriptorKey = "x.ai/tool"

    /// Namespaces that mean "a tool the harness ships", as opposed to an MCP
    /// server's name. Anything else in `namespace` names a server.
    static let builtInNamespaces: Set<String> = ["grok_build", "grok", "builtin", "core"]

    /// The tool descriptor, when the update carries one.
    static func descriptor(_ update: GrokJSON) -> GrokJSON? {
        update["_meta"]?[descriptorKey]
    }

    /// The raw tool name, as a status row should spell it.
    ///
    /// Never `nil`: a call with no name at all is still a call, and `"tool"` is
    /// a truer label for it than dropping the event would be.
    static func name(_ update: GrokJSON) -> String {
        if let name = descriptor(update)?.firstString("name", "label"), !name.isEmpty {
            return name
        }
        if let title = update["title"]?.string.map(trimTitle), !title.isEmpty {
            return title
        }
        return update["kind"]?.string ?? "tool"
    }

    /// The normalised activity behind a tool call.
    ///
    /// One refinement is applied on top of the table: a call whose ACP `kind`
    /// is `"search"` but whose name says `web` is a ``ToolKind/web``, because
    /// that case is documented as covering "a network fetch **or a web
    /// search**", and a board that filed `web_search` next to `grep` would be
    /// grouping a network round-trip with a local one.
    static func kind(_ update: GrokJSON) -> ToolKind {
        let descriptor = descriptor(update)
        if let namespace = descriptor?["namespace"]?.string,
           !namespace.isEmpty,
           !builtInNamespaces.contains(namespace) {
            // A tool the harness did not ship, reached through a server it
            // connected to. `namespace` is that server's name.
            return .mcp
        }
        if let named = descriptor?.firstString("kind", "name").map({ kind(forName: $0) }),
           named != .other {
            return named
        }
        if let acp = update["kind"]?.string, let mapped = kind(forACPKind: acp) {
            return mapped == .search && isWebNamed(update) ? .web : mapped
        }
        return kind(forName: name(update))
    }

    /// `true` when whatever the update calls this tool says "network".
    private static func isWebNamed(_ update: GrokJSON) -> Bool {
        kind(forName: name(update)) == .web
    }

    /// The ACP `kind` vocabulary an update uses, or `nil` for a value that
    /// carries no activity — `"other"` and anything a later release adds, both
    /// of which should fall through to the name rather than be pinned to
    /// ``ToolKind/other`` by a stale table.
    static func kind(forACPKind acp: String) -> ToolKind? {
        switch acp {
        case "read": .fileRead
        case "edit", "delete", "move": .fileWrite
        case "search": .search
        case "execute": .shell
        case "fetch": .web
        case "think": .other
        default: nil
        }
    }

    /// The activity a tool's *name* implies.
    ///
    /// Order matters and is not alphabetical: `web_search` is a network call
    /// and not a codebase search, and `search_cloudflare_documentation` reached
    /// through an MCP server is neither. The specific tests come first.
    static func kind(forName rawName: String) -> ToolKind {
        let name = rawName.lowercased()
        if name.contains("mcp") { return .mcp }
        if name.contains("web") || name.contains("fetch") || name.contains("browser")
            || name.contains("url") || name.contains("http") {
            return .web
        }
        if name.contains("subagent") || name.contains("spawn") || name.contains("delegate")
            || name.hasPrefix("agent") || name == "task" {
            return .subagent
        }
        if name.contains("todo") || name.contains("plan") { return .plan }
        if name.contains("bash") || name.contains("shell") || name.contains("exec")
            || name.contains("terminal") || name.contains("command") || name.hasPrefix("run") {
            return .shell
        }
        if name.contains("search") || name.contains("grep") || name.contains("glob")
            || name.contains("find") || name.contains("list") || name.contains("ls_") {
            return .search
        }
        if name.contains("write") || name.contains("edit") || name.contains("patch")
            || name.contains("apply") || name.contains("replace") || name.contains("delete")
            || name.contains("create") || name.contains("move") {
            return .fileWrite
        }
        if name.contains("read") || name.contains("view") || name.contains("cat")
            || name.contains("notebook") || name.contains("open") {
            return .fileRead
        }
        return .other
    }

    /// The file, command, url, query, or server the call is aimed at.
    ///
    /// Keys are tried in an order chosen by the kind first — a shell call's
    /// subject is its `command`, a fetch's is its `url` — and then a general
    /// list, so a tool whose input names its subject with a key this table has
    /// never seen still resolves as often as it can. Returns `nil` rather than
    /// guessing: a backend `web_search` call opens with
    /// `rawInput: {"variant": …, "backend": true}`, and the query it ran only
    /// arrives with the result.
    static func target(kind: ToolKind, update: GrokJSON) -> String? {
        if kind == .mcp, let namespace = descriptor(update)?["namespace"]?.string,
           !namespace.isEmpty, !builtInNamespaces.contains(namespace) {
            return namespace
        }
        guard let rawInput = update["rawInput"] else { return nil }
        let preferred: [String]
        switch kind {
        case .shell:
            preferred = ["command", "cmd", "script"]
        case .fileRead, .fileWrite:
            preferred = ["file_path", "filePath", "path", "absolute_path", "target_file", "notebook_path"]
        case .search:
            preferred = ["pattern", "query", "glob"]
        case .web:
            preferred = ["url", "query"]
        case .mcp, .subagent, .plan, .other:
            preferred = []
        }
        let fallback = [
            "url", "file_path", "filePath", "path", "command", "pattern", "query",
            "target_file", "cmd", "name"
        ]
        for key in preferred + fallback {
            if let value = rawInput[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    /// The prose a finished call produced, for a full-text index.
    ///
    /// `content` first — it is the rendered answer, the same text the person
    /// saw — then `rawOutput`, which is the structured result and carries the
    /// `message` of a failure. Empty when the result was structure with no
    /// prose in it at all, which is what a `web_search` returning a list of
    /// urls is.
    static func resultText(_ update: GrokJSON) -> String {
        let content = update["content"]?.joinedText ?? ""
        if !content.isEmpty { return content }
        return update["rawOutput"]?.joinedText ?? ""
    }

    /// `"Web search:"` → `"Web search"`.
    private static func trimTitle(_ title: String) -> String {
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(":") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
