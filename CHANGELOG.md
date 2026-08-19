# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Discovery no longer runs hot: an unknown-path FSEvent triggers rediscovery only when some adapter's new `SourceAdapter.mightBeSessionFile(path:)` says the path could be a session (sidecars such as Grok's `summary.json`, Claude's `tool-results/`, and AntiGravity's presence locks no longer do); the rediscovery throttle is 3 s; each adapter's `discover` runs off the coordinator's actor; `CodexLiveAdapter` caches rollout seeds by inode; `GrokLiveAdapter` probes writer locks only for directories written within three days of the cutoff.
- `SessionStateReducer`: a `liveness` verdict no longer counts as a heartbeat (a hung session can go stale again), and a `sessionStarted` stamped before a session's `endedAt` merges identity instead of reviving it. `LivenessResolver` re-asserts every verdict every 10 ticks (`reassertEvery`) so a host whose state moved underneath it hears "still dead" again.
- `IngestCoordinator` now emits a `sessionStarted` carrying the adapter's seed identity when it registers a source, stamped with the process start or the file's birth time — pids, parents, and directory-decoded cwds finally reach the host. `SessionStateReducer` treats a `sessionStarted` for a live, already-tracked session as an identity merge rather than a restart.

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
- **`GrokLiveAdapter`** — the third live `SourceAdapter`, and the first whose
  session is several files rather than one. Discovers
  `~/.grok/sessions/<percent-encoded cwd>/<session id>/`, seeding the working
  directory from the directory's own name and the title, model, and agent name
  from `summary.json`. A session listed in `~/.grok/active_sessions.json` or
  holding one of its per-file writer locks is discovered whatever its mtime
  says.
  - `GrokSessionTailer` — a `JSONLTailer` per file, merged into one stream
    ordered by the source's own timestamp and re-stamped with one monotonic
    sequence. Its cursor is a `SourceCursor.composite` keyed by path, so one
    file rotating re-seeds that file and leaves the others where they were.
  - `GrokRecordMapper` — pure, static, `Sendable` mapping for
    `events.jsonl`, `updates.jsonl`, and `chat_history.jsonl`, with a
    documented table naming which file each fact is read from. Prompts, prose,
    reasoning, and the whole tool-call lifecycle come from `updates.jsonl`;
    turn boundaries, permissions, and the model come from `events.jsonl`;
    nothing is read from `chat_history.jsonl`, whose every fact appears in
    `updates.jsonl` stamped and in a shape that has not changed between
    releases. `phase_changed` is dropped by default — two of its phases fire
    per token — and `Options.includePhaseNotes` turns on a note for the rest.
    `turn_started` deliberately does not open a turn: it is not written once
    per prompt, and the prompt is.
  - `GrokToolCall` — resolves a call's name, `ToolKind`, and target from the
    three places Grok records them, preferring the `_meta["x.ai/tool"]`
    descriptor over the ACP `kind` over the display title. A descriptor
    `namespace` that is not the harness's own names an MCP server.
  - `GrokRecords` — `GrokJSON` plus lenient decoders for the three line shapes,
    for `summary.json` and `signals.json`, and for the `active_sessions.json`
    registry, whose entries are matched by any string field so that a renamed
    field degrades into "listed" rather than into "nothing is running".
  - `GrokSessionsPath` — exact, lossless decoding of the percent-encoded
    working directory a session directory is named for.
  - Liveness: the registry first — a listed pid missing from the process table
    is an entry that outlived a killed process, and is read as dead — then the
    per-file `flock(2)` locks, which the kernel will not attribute because Grok
    is Rust, then the session directory's age.
- **`CursorLiveAdapter`** — the third live `SourceAdapter`, and the first over a
  database rather than a log. Discovers `~/.cursor/chats/*/*/store.db` by
  `meta.json`'s `updatedAtMs` and the store's own mtime, and includes a store
  whatever its age when a `cursor-agent-worker-*.pid` names a live process and
  the store's project has a `worker.sock`. A session's `primaryPath` is the
  `.db`, so `IngestCoordinator` registers the `-wal` / `-shm` siblings that
  actually move during a turn. Liveness: a worker pid whose environment carries
  `CURSOR_AGENT_CHAT_ID` for this agent (or whose cwd is the session's) is
  alive; failing that a WAL written in the last 30 s is alive, a `worker.sock`
  that accepts a connection is unknown, and a store quiet for ten minutes is
  dead. The command line is never read — `cursor-agent` carries its API key in
  argv.
  - `CursorStoreReader` — read-only access to the store through
    `LiveSQLiteReader`, and the incremental walk of its content-addressed blob
    graph. Split in two on purpose: `walk` finds where the messages are without
    parsing any JSON, `decode` parses only the ones a caller needs. A second
    walk carrying the first one's visit set fetches only the new turn, which
    holds whether a new head re-lists the conversation or chains to its
    predecessor.
  - `CursorSessionTailer` — composes the store walk with a `JSONLTailer` over
    the thin transcript, under one `.composite` cursor. The store's half is
    `.blobHead("<head>|<anchor>")`: the head answers "did anything change" for
    the price of one small query, and the anchor — the id of the last message
    emitted, stable because the store is content-addressed — is what a
    relaunched host resumes from without re-emitting or re-parsing a
    conversation.
  - `CursorMessageMapper` / `CursorToolMapping` — pure translation of one store
    message: the `<user_query>` wrapper stripped off a prompt, reasoning
    reported as a state and never as text, tool calls normalised to `ToolKind`
    with arguments narrowed to a whitelist, tool results paired on Cursor's own
    call id, and a `system` message dropped whole.
  - `CursorThinTranscriptMapper` — the turn skeleton. It owns `userPrompt` and
    `turnEnded` and the store owns everything else, because the reducer counts
    a turn per prompt and two sources reporting one would double every turn. An
    IDE-started agent has no transcript, and then the store owns `userPrompt`
    too.
  - `CursorPaths` / `CursorStoreMeta` / `CursorAgentMeta` / `CursorWorkerProbe`
    — the cwd slug that joins a store to its transcript, the hex-JSON
    conversation card, the `meta.json` sidecar, and the two probes that tell a
    live `cursor-agent` from the pid file and socket one leaves behind when it
    crashes.

### Changed
- `LiveSQLiteReader` and `ProtobufWireReader` are `public`. Both are read by
  `AgentSessionLive`'s Cursor adapter, and a second copy of the open flags, the
  busy timeout, the snapshot fallback, and varint framing is how two modules
  end up disagreeing about somebody else's live database. Behaviour is
  unchanged.
- **`AntigravityLiveAdapter`** — the third live `SourceAdapter`, and the first
  over a store that rewrites rather than appends. Covers both data roots —
  `~/.gemini/antigravity-cli` (`variant` `"cli"`) and `~/.gemini/antigravity`
  (`"ide"`) — with discovery unioning the CLI's `conversation_summaries.db`
  against a walk of both `conversations` directories, since that index names
  only a fraction of the databases on disk. Freshness is the newer of a store's
  own mtime and its `-wal` sibling's, because in WAL mode the `.db` can sit
  untouched through a busy hour. Liveness takes, in order: a held
  `presence/<id>.lock`, an `agy` process whose `ANTIGRAVITY_CONVERSATION_ID`
  names the conversation (which also yields a pid), a presence file touched
  within a minute, the index's `killed` / `not_fully_idle` flags, and last the
  store's age.
- `AntigravityConversationTailer` — diffs instead of walking. A tool call is one
  `steps` row whose `status` column walks `PENDING → RUNNING → DONE` in place,
  so each poll re-reads the rows still open behind its cursor and emits only
  the transitions. Cursor is `.rowID(<highest idx>)`; a resume re-reads the last
  32 rows and adopts them without replaying, which leaves one documented gap —
  a step that opened *and* closed while the host was down produces neither half.
- `AntigravityStepMapper` — pure mapping of one row plus its previous state to
  events: `USER_INPUT` to a prompt and a turn, `PLANNER_RESPONSE` to thinking
  and then prose, tool rows to a matched start/finish pair, `WAITING` (and an
  unfinished `ASK_QUESTION`) to a permission request and its resolution, and
  `ERROR_MESSAGE` to a note. Usage carries prompt tokens only, and only for a
  step that names the model request it billed against — the payload records no
  completion count this decoder is willing to claim.
- `AntigravityStepType` / `AntigravityStepStatus` / `AntigravityStepSource` /
  `AntigravityTrajectorySource` / `AntigravityTrajectoryType` — the complete
  enum tables (118 step types among them), decoded from the `agy` binary's
  embedded `FileDescriptorProto` on 2026-08-19 rather than inferred from a
  corpus, each with a `label` and, for step types, a `ToolKind`.
- `AntigravityStepPayload` — a shallow, tolerant decode of the undocumented
  `steps.step_payload` protobuf: start and end timestamps, step source, the
  `ToolCall` submessage, the repeated status-transition log, prompt tokens, the
  request id, and a text preview that refuses anything reading as an identifier
  rather than guessing.
- `AntigravityConversationReader` / `AntigravitySummariesReader` — read-only
  SQLite over a conversation database and over the CLI's side index, tolerating
  a live `-wal` and an older build missing the newer summary columns.
- `AntigravityConversationRegistry` — holds what only the summaries store knows
  (parent conversation, `killed`, `not_fully_idle`) so a poll and a synchronous
  liveness probe can have it without running SQL, and turns a
  `parent_conversation_id` into `subagentStarted` on the parent's stream.

### Changed

- `ProtobufWireReader` and `LiveSQLiteReader` are `public`. Both were internal
  to `AgentSessionKit`; the live adapters over SQLite-backed stores need them,
  and a second copy of either would drift. Visibility only — no behaviour
  changed.

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
