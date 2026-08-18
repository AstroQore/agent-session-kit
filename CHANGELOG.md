# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

Initial extraction from [Vibe Bar](https://github.com/AstroQore/vibe-bar),
where this code lived inside the application target.

- **`AgentSessionKit`** — session discovery, parsing, and indexing for eight
  harnesses across seven on-disk providers: Codex / ChatGPT Work, Claude Code,
  Claude Cowork, Gemini CLI, AntiGravity, Grok Build, and Cursor.
  - `SessionProviderAdapter` and `SessionProviderRegistry`, one adapter per
    provider, each taking an explicit `homeDirectory`.
  - `SessionIndexStore` — SQLite + FTS5 (`trigram`) index over sessions and,
    optionally, message bodies. No default location: the caller names the
    file.
  - `SessionIndexService` — incremental refresh keyed on a nanosecond
    mtime + size fingerprint, with the WAL sibling folded in so a live SQLite
    store is not mistaken for an unchanged one.
  - `SessionDeleter` and `SessionDeletionPlan` — deletion described as data
    and re-verified at execution time; refuses symlinked targets, paths
    outside a provider root, and the three providers whose stores another
    running app owns.
  - `SessionResumeCommandBuilder` — the shell line that reopens a session.
  - `Harness` / `HarnessCatalog` — naming only. The billing axis stays with
    the host application.
  - Utilities: `JSONLLineScanner`, `JSONLHeadTail`, `RealHomeDirectory`,
    `ClaudeCoworkPaths`, `CodexOriginator`, `KitLog`.
- **MCP transport** — `MCPSocketServer` (newline-delimited JSON-RPC over a
  0600 `AF_UNIX` socket, with stale-socket recovery that will not unlink a
  live peer), `MCPStdioBridge` (byte pump for clients that spawn a command),
  and the wire types `MCPJSON`, `MCPRequest`, `MCPResponse`, `MCPRPCError`,
  `MCPTool`, `MCPResource`, `MCPToolFailure`, `MCPArguments`. Dispatch,
  tool catalogs, and DTOs stay with the host.
- **`AgentSessionLive`** — the unified event model, the state reducer, and
  the source protocols for the file-watching and incremental-tailing layer.
  The watcher and the per-harness adapters are still to come; everything they
  will speak is here.
  - `SessionKey` — a harness plus that harness's own session id, with a
    stable `"<harness>:<id>"` string form that survives ids containing
    colons. `SessionIdentity` and its sparse `SessionIdentityPatch` carry
    everything else known about a session, and `ParentLink` records *why*
    two sessions are believed to be parent and child.
  - `AgentEvent` / `AgentEventKind` — one harness-agnostic vocabulary for
    prompts, turns, thinking, tool calls, permission prompts, subagents,
    usage, compaction, session end, and liveness. `RawRef` points back into
    the source for drill-down; `ToolKind` normalises the tool names eight
    harnesses spell eight ways.
  - `SessionStateReducer` — a pure, total fold from events to a
    `SessionSnapshot`: derived `SessionState`, the `PendingSet` of open tool
    calls / children / permission prompt, turn and tool counters, token
    totals, and staleness recomputed against an injected clock.
  - `SourceAdapter`, `SessionTailer`, `SessionSource`, `SourceCursor`,
    `LivenessHint`, and `ProcessTableReading` / `ProcessRecord` — the
    protocols a per-harness adapter implements, with the process table
    injected so that liveness is testable without depending on what happens
    to be running.
  - `EventText` and `ArgvSanitizer` — preview truncation, and credential
    redaction for command lines and process environments by both flag
    position and value shape.

### Changed from the Vibe Bar originals

- `MCPSocketServer` takes an `MCPLineHandler` and an explicit `socketPath`
  plus an `ensureDirectory` hook, instead of a concrete server type and a
  hard-coded `~/.vibebar/mcp.sock`.
- `MCPStdioBridge` is parametrized by `MCPStdioBridgeConfig` (flag,
  environment key, default socket path, and the not-running message) rather
  than hard-coding Vibe Bar's.
- `SessionIndexStore.init` requires a `url`.
- `CostUsageScanner.forEachJSONLLine` became `JSONLLineScanner.forEachLine`
  with identical semantics and return value.
- `AntigravitySessionReader` became `AntigravityGenMetadataReader`.
