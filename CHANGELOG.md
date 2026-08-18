# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `AgentEventKind.textBody(role:text:toolCallID:)` + `TextBodyRole` — full-text bodies for hosts that keep a searchable index; reducer treats it as a heartbeat; adapters cap at `AgentEventKind.textBodyLimit` (32 KiB).
- **`ClaudeLiveAdapter`** — the first live `SourceAdapter`. Discovers transcripts under `~/.claude/projects` and `~/.config/claude/projects`, counting a session active when it was written to since the cutoff *or* when `~/.claude/sessions` names a process driving it; returns subagent transcripts as sessions of their own, keyed `<session id>/agent-<agent id>`.
  - `ClaudeRecordMapper` — pure, stateless translation of one transcript line into events: prompts (`isMeta` context excluded), thinking, assistant prose, tool calls normalised to `ToolKind` by `ClaudeToolMapping`, tool results with their `toolUseResult` sidecar text, usage with cache reads and writes folded together, `end_turn` turn ends, compaction, pinned titles, worktree moves, and queued prompts.
  - `ClaudeTranscriptRecord` — lenient parsing: unknown record types and fields cost nothing, `message.content` is tolerated as a string or a block array, and `tool_use` inputs are narrowed to a whitelist so an `Edit` does not pull a file body into memory.
  - `ClaudeSessionsDirectory` / `ClaudeLiveSession` — the pid ↔ session ↔ cwd table liveness rests on, since Claude Code holds no lock on its transcript. Its `procStart` is parsed as **UTC**, which is how Claude Code writes it.
  - `ClaudeSubagentLinker` — joins the parent's `Task` tool-use id to the child's `agent-<id>.meta.json` at discovery, and announces `subagentStarted` / `subagentFinished` on the parent's stream.
  - `ClaudeProjectPath` — best-effort, file-system-checked decoding of the lossy project-directory encoding, for the last-resort case where neither the sessions entry nor the transcript head names a cwd.
- **`CodexLiveAdapter`** — the second live `SourceAdapter`. Discovers
  `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-*.jsonl` and
  `~/.codex/archived_sessions` by directory name so a machine with years of
  transcripts costs a `readdir` per day rather than a `stat` per file, and
  always includes a thread whose `~/.codex/thread-writer-locks/<id>.lock` is
  held, however old its rollout. Liveness comes from that lock — Codex is Rust,
  so it is a `flock(2)` the kernel will not attribute, which
  `LockFileProbe.LockState.heldByUnknownOwner` reports and this adapter reads
  as held; with no lock file at all it falls back to the rollout's age.
- `CodexRecordMapper` — pure, static, `Sendable` mapping from one rollout line
  to `AgentEvent`s, with the duplicate halves of Codex's two-audience log
  resolved by choosing a source: prompts from `event_msg.user_message`, prose
  from `response_item.message`. A `patch_apply_end`, `web_search_end`, or
  `mcp_tool_call_end` carrying a non-`call_`-prefixed id is expanded into a
  tool-call pair, because work the desktop app's JavaScript sandbox did is
  recorded nowhere else. Token usage is taken from `last_token_usage`, which is
  the per-step delta the reducer sums, never the running total.
- `CodexRolloutRecord` / `CodexJSON` — a lenient, `Sendable` value tree for
  records whose shape changes between Codex vintages and between surfaces.
- `CodexSubagentLinker` — remembers `sub_agent_activity` spawn edges so a child
  thread discovered on its own is seeded with the parent that spawned it and
  the call id that did it.

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
  - `FSEventsWatcher` — one recursive watch over a set of roots, delivered as
    `AsyncStream<FSEventBatch>` with per-path coalescing. Roots that do not
    exist yet are watched through their nearest existing ancestor and the
    stream re-arms when they appear, so a harness installed after launch does
    not need a restart. Paths are filtered against the declared roots and
    rewritten back into the caller's own vocabulary, because FSEvents reports
    canonical paths (`/private/var/…` for a `/var/…` root) and a naive prefix
    filter would drop every event.
  - `JSONLTailer` — incremental tailing of one append-only JSONL file, given a
    `(Data, JSONLLineRef) -> [AgentEvent]` decoder. Detects rotation by inode
    and truncation by size, holds a half-written trailing line until its
    newline arrives, keeps the cursor at a record boundary so a persisted one
    always resumes cleanly, and seeds a cold start from a bounded window at
    the end of the file. A source that vanished yields nothing and keeps its
    cursor; a line the decoder rejects is skipped.
  - `SQLiteChangeWatcher` — change ticks for a `.db` and its `-wal` / `-shm`
    siblings, driven by an FSEvents batch, by a poll, or by both.
  - `IngestCoordinator` — the one thing a host starts. Owns the watcher, a
    tailer registry keyed by primary path, a per-path debounce (50 ms; 250 ms
    for database files), a safety-net poll (2 s for SQLite-backed sources,
    10 s for file-backed ones), and a rediscovery pass every 15 s. Emits
    `AsyncStream<AgentEvent>` and a second `AsyncStream<IngestNotice>` for
    diagnostics. Nothing inside the pipeline drops an event; see
    `TailerBackpressure`.
  - `SourceCursorStore`, with `InMemoryCursorStore` and `JSONFileCursorStore`
    — resume points persisted every two seconds when dirty and once more on
    `stop()`. A host with its own database implements the protocol instead.
  - `ProcessTable` — the real `ProcessTableReading`, over `proc_listpids`,
    `proc_pidinfo`, `proc_pidpath`, and `sysctl KERN_PROCARGS2`. Command
    lines, environments, and working directories are read only for the
    current user's own processes; the snapshot is cached so a liveness tick
    costs one read rather than one per session.
  - `LockFileProbe` — who holds an advisory lock on a file, via
    `fcntl(F_GETLK)`, distinguishing a named POSIX record-lock holder from a
    `flock(2)` lock the kernel will not name.
  - `LivenessResolver` — combines each adapter's `probeLiveness` with a
    generic `(pid, startTime)` check and emits `liveness` events only on a
    transition, because pids are recycled and a board that re-states an
    unchanged answer every three seconds is a board that re-renders forever.

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

### Changed

- `PrivacyPreservingHash` is now `public`, for hosts that want the same
  content-addressed, unlinkable component the kit uses internally for
  session paths.
- `MCPStdioBridgeConfig.defaultSocketPath` is now `@Sendable () -> String`
  rather than a stored `String`, so a default that depends on the real home
  directory is resolved lazily, only when the socket path is actually
  needed, instead of being baked in when the config is built. A
  backward-compatible `String` initializer overload is still there for
  existing callers.
- `MCPStdioBridge` gained an instance API — `init(config:)` plus unlabeled
  `isRequested(arguments:)`, `socketPath(environment:)`, and `run(...)` — as
  a thin convenience over the unchanged static functions of the same names.
