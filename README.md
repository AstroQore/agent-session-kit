# agent-session-kit

A Swift package that reads the session stores AI coding agents leave on your
Mac, and serves them over MCP.

Every coding agent keeps a local record of what you asked it — Codex writes
rollout JSONL, Claude Code writes transcript JSONL, Cursor and AntiGravity
write SQLite databases another process holds open. Each one has its own
layout, its own idea of a "session id", and its own way of spelling a
timestamp. This package hides all of that behind one adapter protocol, a
searchable index, and a local MCP transport.

No third-party dependencies. Foundation, Darwin, and the system SQLite.

```swift
.package(url: "https://github.com/AstroQore/agent-session-kit", from: "0.1.0")
```

## Targets

| Target | What it is |
| ------ | ---------- |
| `AgentSessionKit` | Discovery, parsing, deletion planning, the FTS5 session index, and the MCP Unix-socket / stdio transport. |
| `AgentSessionLive` | Live views over the same stores — file watching and incremental tailing. Placeholder today. |

Requires macOS 26 and Swift 6.2.

## Supported harnesses

| Harness | On-disk location | Sessions | Model | Delete |
| ------- | ---------------- | -------- | ----- | ------ |
| Codex | `~/.codex/sessions`, `~/.codex/archived_sessions` | ✅ | ✅ | ✅ |
| ChatGPT Work | same tree, `originator == codex_work_desktop` | ✅ | ✅ | ✅ |
| Claude Code | `~/.claude/projects`, `~/.config/claude/projects` | ✅ | ✅ | ✅ |
| Claude Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects` | ✅ | ✅ | ❌ Claude.app's container |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.jsonl` | ✅ | ⚠️ newer vintages only | ✅ |
| AntiGravity | `~/.gemini/antigravity{,-cli,-ide}/conversations/*.db` | ✅ | ✅ | ❌ live WAL handles |
| Grok Build | `~/.grok/sessions/**`, `~/.grok/archived_sessions` | ✅ | ✅ | ✅ |
| Cursor | `~/.cursor/chats/**/store.db` | ✅ | ⚠️ when a turn recorded one | ❌ store stays open |

Where a ⚠️ appears the log genuinely does not carry the value — an aborted
Cursor conversation records no model name at all, and old Gemini CLI chats
predate the per-turn `model` field. Those stay `nil`. A model is never
inferred from the vendor's "usual" one; a wrong model on a row is worse than
an empty one.

Three providers are listed and readable but never deletable, because another
running app owns the store. `SessionProvider.supportsDeletion` says so up
front, and the adapters fail closed with
`SessionDeleteError.providerIsReadOnly`.

## Usage

### List and read

```swift
import AgentSessionKit

let registry = SessionProviderRegistry.standard()

for summary in registry.adapters.flatMap({ $0.discoverSessions(homeDirectory: home) }) {
    print(summary.effectiveHarness.displayName, summary.title ?? "—", summary.lastActiveAt ?? .distantPast)
}

let adapter = registry.adapter(for: .codex)!
let transcript = try adapter.parseTranscript(fileURL: url, range: 0..<50)
```

`discoverSessions` reads only the head and tail of each file, so listing a
tree of multi-megabyte transcripts stays bounded.

### Index and search

```swift
let store   = try SessionIndexStore(url: myAppSupport.appending(path: "sessions.sqlite"))
let service = SessionIndexService(
    homeDirectory: RealHomeDirectory.path,
    store: store,
    registry: registry,
    bodyIndexing: { true }        // off ⇒ metadata only, and bodies are dropped
)

await service.refreshIndex { done, total in print("\(done)/\(total)") }
let hits = try await service.search("sqlite migration", harnesses: [.codex, .claudeCode])
```

The index is incremental: a file is re-read only when its fingerprint —
nanosecond mtime plus size, WAL sibling folded in — has moved. Full-text
search uses an FTS5 `trigram` tokenizer, the only built-in one that matches
inside words, which is what makes substring search work for CJK and for
identifiers alike.

`SessionIndexStore` has **no default location**. You name the file.

### Serve over MCP

```swift
struct MyHandler: MCPLineHandler {
    func handle(line: Data) async -> Data? { /* dispatch JSON-RPC */ }
}

let server = MCPSocketServer(
    handler: MyHandler(),
    socketPath: mySupportDirectory.appending(path: "mcp.sock").path,
    ensureDirectory: { try FileManager.default.createDirectory(/* 0700 */) }
)
try server.start()
```

Newline-delimited JSON-RPC over `AF_UNIX`, socket mode 0600. No TCP, no port,
no token: the filesystem is the whole authentication story, and a token file
would only add a secret to leak. A socket left behind by a crash is unlinked;
a socket someone is *answering* on is not — the server reports
`.socketOwnedByAnotherInstance` rather than cutting off the agents attached to
the other copy.

`MCPStdioBridge` runs the same binary as a plain stdio MCP server that pumps
bytes to that socket, which is how MCP clients that spawn a command reach a
running GUI app:

```swift
let config = MCPStdioBridgeConfig(
    flag: "--mcp-stdio",
    envKey: "MYAPP_MCP_SOCKET",
    defaultSocketPath: defaultSocket
)
if MCPStdioBridge.isRequested(config) { exit(MCPStdioBridge.run(config)) }
```

`MCPJSON`, `MCPRequest`, `MCPResponse`, `MCPTool`, `MCPResource`, and
`MCPArguments` are here too, so a host writes its tool catalog and its
dispatch and nothing else.

## Privacy

This package reads the most personal thing on a developer's machine: the
record of everything they asked an agent. It is built to be boring about it.

- **Explicit roots.** Every discovery call takes a `homeDirectory`. Nothing
  scans "the filesystem".
- **No symlink following**, ever — while enumerating or while deleting.
- **No writes outside a caller-provided path.** The index location is a
  parameter; the MCP server creates no directory of its own.
- **Deletes are verified twice.** A plan names the file to re-parse and the
  session id that must still be in it, and the deleter refuses on any
  mismatch, any symlinked target, and any path outside a provider root.
- **No network.** Nothing here opens a socket to anywhere but a local path.
- **No secrets in logs.** `KitLog.sanitize` redacts token-shaped runs, and the
  code logs file *names*, never paths or transcript bodies.

Test fixtures use `/Users/example` and synthetic ids. Never commit a real
username, path, org id, or token.

## Used by

- [Vibe Bar](https://github.com/AstroQore/vibe-bar) — macOS menu-bar app for
  agent quota, usage, and cost. This package was extracted from it.
- Auspex.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
