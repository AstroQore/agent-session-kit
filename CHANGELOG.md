# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-08-19

Sessions learn to say what they were asked for and how to get back into
them, Grok Bot goes live, and the package learns how to cut its own
releases.

### Added
- **`SessionBrief` on every `SessionSnapshot`.** The state machine says what a
  session is *doing*; it could not say what anybody asked it for. The brief
  carries the assignment (`firstPrompt`, with the `firstPromptAt` it was given
  at), the latest instruction, the last thing the model said in prose, and when
  a turn last closed — folded by `SessionStateReducer` from `userPrompt`,
  `assistantText`, and `turnEnded`, the three events all eight live adapters
  already emit. No adapter changed.
- **A filter for the things a person did not type.** Half of what a harness
  records as a "user message" is machinery: Claude Code spells a slash command
  as `<command-name>…</command-name>`, injects context as `<system-reminder>`,
  and spills hook output into `<local-command-…>`; Codex prepends
  `<environment_context>` and `<user_instructions>`.
  `SessionBrief.instruction(_:)` strips those blocks — including the ones a
  200-character preview cut in half, from either end — and refuses what is left
  when it is empty or a bare slash command. A rejected prompt moves nothing:
  not the assignment, not the latest prompt, not `lastPromptAt`. Every field
  guards its own clock, so a turn flushed out of order cannot overwrite a newer
  one, and the brief survives an explicit restart.
- **`SessionResume`** — "how do I get back to this one?", answered from a
  `SessionIdentity`. `resumeCommand(for:)` returns a cwd-aware
  `cd '<dir>' && <command>` or `nil`; `availability(for:)` returns the same
  answer plus the sentence to put in a disabled menu item, because Claude
  Cowork, Cursor, and Grok Bot have no command-line entry point at all and a
  menu item that quietly disappears explains nothing. `Harness.sessionProvider`
  is the inverse of `SessionProvider.defaultHarness`, which is not injective —
  Codex and ChatGPT Work share one rollout tree.
- **`GrokBotLiveAdapter`** — Grok Bot is now live, not just indexed. A
  conversation is a JSON document the desktop client rewrites whole, so
  `GrokBotTranscriptTailer` diffs the file against itself rather than walking
  it: a poll asks which entries are new and which of the ones already read have
  stopped streaming, and the cursor is `.blobHead(<id of the last entry
  consumed>)` because entry ids survive a rewrite and a byte offset does not.
  Two `stat` calls short-circuit a poll with nothing to read — the client
  rewrites the file on every step of a streaming reply. A streaming entry
  produces `thinking` and nothing else; the words come out of the read that
  finds the flag cleared. `send-message` is the bot answering the person and a
  `message` with `role: "user"` is inbound, matching `GrokBotSessionAdapter`
  exactly, and renames, automations, widgets, secret requests, and attachments
  ride in `note` rather than pretending to be turns.
- **A needs-you signal for Grok Bot.** The roster slice travels as an auxiliary
  path and its `awaitingUserResponse` becomes
  `permissionRequested(id: "grokbot:<bot>", tool: nil)`, resolving when the flag
  clears, stamped with the roster file's own mtime. It is the only field
  anywhere in this store that says a person is needed, and a conversation
  carrying it is discovered however old its timestamps are.
- **Liveness about the client, not the conversation.** The conversation runs on
  xAI's servers, so no `Grok Bot` process and no fresh
  `~/.grokbot/local-exec-supervisor.json` heartbeat ends every conversation at
  once, a running client with a replica written in the last two minutes is
  alive, and a running client with a quiet conversation answers `unknown`
  however long the quiet has lasted — idle is not ended. That heartbeat is the
  only file in `~/.grokbot` this package opens, and the directory is
  deliberately not watched: its neighbours hold a daemon token and a
  credential.
- **`AgentSessionKitInfo`** — the version of the package, written down where
  a statically linked host can read it. There is nothing else to ask: once
  this code is compiled into somebody's binary there is no bundle, no
  `Info.plist`, and no dylib left to interrogate. `version` is pinned to the
  top released section of this file by `AgentSessionKitInfoTests`, so the
  constant and the changelog cannot drift apart without failing the suite.
  `repositoryURL` and `releaseNotesURL(for:)` are there so a host showing the
  number has somewhere to send the reader; the tag normalizer tolerates the
  `v` prefix this project does not use, because a caller reading a tag out of
  the GitHub API should not have to know that.
- **A release workflow.** Pushing a bare `X.Y.Z` tag runs
  `.github/workflows/release.yml`: it refuses the tag unless
  `AgentSessionKitInfo.version` and a `## [X.Y.Z]` changelog section both
  agree with it, builds, tests, and then publishes a GitHub Release whose
  notes are that changelog section. Every check fails loudly — a tag that
  does not match its own source is not a release, and the workflow would
  rather publish nothing than publish a lie.
- **[RELEASING.md](RELEASING.md)** — the semver policy while this package is
  0.x, the exact steps to cut a version, what a consumer has to do
  afterwards, and the rule that a published tag never moves.

### Changed
- **`AgentSessionLive.eventSchemaVersion` is 2.** A field was added to
  `SessionSnapshot`, which is encoded structurally, so a host that persisted
  snapshots re-seeds rather than decoding rows from a model it no longer
  speaks. That is the contract the constant already documented.
- **`GrokBotSessionAdapter`'s key vocabulary is public.** The store path, the
  blob extension, the variant, `decodedKey`, `transcriptKey`, `rosterKey`,
  `rosterURL`, and `rosterRows` are what the live adapter reads the same
  directory with; a second copy of any of it is how a store ends up listed on
  one screen and missing from the other. No behaviour changed and nothing was
  renamed. `RosterRow` gains `awaitingUserResponse`, absent reading as `false`.

### Note
- Nothing here is breaking, so 0.3.0 is a minor bump over 0.2.0 (`fd0c95a`).
  It is the first tag to carry a published GitHub Release; 0.1.0 and 0.2.0
  exist as tags only. A host pinning this package `exact:` sees none of it
  until it bumps the pin and ships a build of its own — see
  [RELEASING.md](RELEASING.md).

## [0.2.0] - 2026-08-19

Grok Bot joins the provider list, Claude Cowork and ChatGPT Work become
first-class in the live layer, and the suite is green on CI for the first
time.

### Added
- **`GrokBotSessionAdapter`** — xAI's standalone `Grok Bot.app` is a listed
  provider. Its client caches every conversation under
  `~/Library/Application Support/Grok Bot/sand-client-persistence/`, where each
  file is named after the lowercase, unpadded RFC 4648 base32 of the key it
  holds, so discovery decodes stems through a new `Base32` and claims only
  `sand.client.slice.account.<account>.transcript.replicas.<bot uuid>`. The
  per-account `roster.last-roster` slice supplies the name a transcript does
  not carry, cached against its own mtime and size so a scan parses it once
  rather than once per bot. Entries are read from the transcript owner's point
  of view: `send-message` is the bot's own turn, an inbound `fromAgent`
  message is another bot prompting this one (name-prefixed, still `.user`), an
  `assistant` turn with a `toAgent` is this bot answering that one
  (`→ Name: …`), and renames and attachments count as turns without being
  shown. File order is kept, because a couple of conversations have
  `timestampMs` running backwards. `lastActiveAt` is the later of the newest
  entry and the roster's `lastActivityAt` — the two clocks disagree in both
  directions.
- **Grok Bot is read-only, and says so.** `SessionProvider.grokBot` reports
  `supportsDeletion == false`, the adapter fails closed with
  `SessionDeleteError.providerIsReadOnly(.grokBot)`, and
  `SessionResumeCommandBuilder` refuses on every variant: the conversation
  runs on xAI's servers and there is no CLI to hand it back to. `model` is
  always `nil` for the same reason — the run left no local trace of what
  answered.
- **`Harness.grokBot`** — Grok Bot is its own harness, not a second name for
  Grok Build. They share a company and nothing else: one is a local CLI with
  rollouts on disk, the other a cloud bot whose client caches conversations.
- **`ClaudeCoworkLiveAdapter`** — Claude Cowork is now live, not just indexed.
  Discovery walks `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects`
  through `ClaudeCoworkPaths`, the same sweep the on-disk index uses, so a
  transcript can never be live here and missing there. Cowork writes
  byte-identical JSONL to Claude Code, so the record mapper, the tailer, and
  the seeding rules are shared through a new `ClaudeSourceBuilder` rather than
  copied; only the roots and the liveness rule are the adapter's own.
  Liveness has no pid file and no writer lock to read, so it is taken from the
  process that launched the run: a binary under `/Applications/Claude.app`
  whose environment carries this session's `CLAUDE_CODE_SESSION_ID` → alive
  with that pid; otherwise a transcript written in the last two minutes →
  alive, longer than ten → dead, and `unknown` in between.
- **ChatGPT Work is its own harness in the live layer.** `CodexLiveAdapter`
  keys a rollout by `session_meta.originator` through `CodexOriginator`, so a
  thread written by ChatGPT Work mode in the desktop app
  (`originator == "codex_work_desktop"`) becomes
  `SessionKey(.chatgptWork, …)` and every event, child link, and cursor
  follows that key. Anything unrecognised — including a rollout with no header
  — stays on `.codex` rather than being invented as ChatGPT Work usage.
- **`SourceAdapter.handledHarnesses`** — the harnesses an adapter can key and
  probe, defaulting to `[harness]`. `CodexLiveAdapter` reports
  `[.codex, .chatgptWork]`, and `LivenessResolver` now indexes adapters by
  this rather than by the primary harness; without it every ChatGPT Work
  session would get no probe at all and resolve `unknown` forever.

### Fixed
- The two `ClaudeProjectPath` round-trip tests no longer depend on the shape of
  `NSTemporaryDirectory()`. A GitHub runner's temp path contains `_`
  (`/var/folders/df/…wsm_g8s…gn/T/`), which `encode` maps to `-` like every
  other lossy character and no decode can put back, so both expectations
  failed on CI for a reason that was never the decoder's. Those two fixtures
  are rooted at `/private/tmp`, every component of which survives the
  encoding; the rest of the suite still builds its trees under
  `NSTemporaryDirectory()`.

## [0.1.0] - 2026-08-19

First tagged release: the extraction from Vibe Bar plus the whole live layer.

### Fixed
- Discovery no longer runs hot: an unknown-path FSEvent triggers rediscovery only when some adapter's new `SourceAdapter.mightBeSessionFile(path:)` says the path could be a session (sidecars such as Grok's `summary.json`, Claude's `tool-results/`, and AntiGravity's presence locks no longer do); the rediscovery throttle is 3 s; each adapter's `discover` runs off the coordinator's actor; `CodexLiveAdapter` caches rollout seeds by inode; `GrokLiveAdapter` probes writer locks only for directories written within three days of the cutoff.
- `SessionStateReducer`: a `liveness` verdict no longer counts as a heartbeat (a hung session can go stale again), and a `sessionStarted` stamped before a session's `endedAt` merges identity instead of reviving it. `LivenessResolver` re-asserts every verdict every 10 ticks (`reassertEvery`) so a host whose state moved underneath it hears "still dead" again.
- `IngestCoordinator` now emits a `sessionStarted` carrying the adapter's seed identity when it registers a source, stamped with the process start or the file's birth time — pids, parents, and directory-decoded cwds finally reach the host. `SessionStateReducer` treats a `sessionStarted` for a live, already-tracked session as an identity merge rather than a restart.

### Added
- **`ProcessLinker`** — infers the parent/child links between sessions that no
  log records, which is the only way a Claude Code tool call that ran
  `codex exec` is ever seen as one pair. Given the current identities and a
  `ProcessTableReading` it proposes one `ProcessLink` per parentless session:
  first from the environment (a well-known session-id variable in the child's
  own environment naming a session on the board → `.envInherited`, high
  confidence), then from the spawn tree (`ancestors(of:)`, or a pid-carrying
  variable for a child that was re-parented → `.spawnedProcess`, medium).
  Refuses self-links, cycles through recorded *or* proposed parents, and every
  ambiguous match — two sessions on one pid, one id claimed by two harnesses.
  Ordered by child key, so two runs over the same inputs agree.
  - `linkFromToolCommand(parent:command:startedAt:candidates:)` is the pure
    hook for the case with no pid at all: a shell command from the parent's log
    matched against a candidate of the harness that command launches, whose
    `procStart` is within ±10 s and whose cwd matches the parent's. Ambiguity
    answers `nil` rather than guessing. A host wires it to its own event
    stream; `infer` never calls it.
  - `identityPatches(from:)` turns links into `SessionIdentityPatch`es a host
    feeds back through `AgentEventKind.identityUpdated`.
- **`SessionEnvironmentVariables`** — one table of the variables each harness
  passes to the processes it launches (`CLAUDE_CODE_SESSION_ID`,
  `CODEX_SESSION_ID` / `CODEX_THREAD_ID`, `GROK_SESSION_ID`,
  `CURSOR_AGENT_CHAT_ID`, `ANTIGRAVITY_CONVERSATION_ID` /
  `ANTIGRAVITY_TRAJECTORY_ID`, plus `CLAUDE_PID` for the pid-carrying kind).
  `CursorLiveAdapter.chatIDVariable` and
  `AntigravityLiveAdapter.conversationEnvironmentKey` now read from it rather
  than spelling their own name, so the cross-harness linker and the
  per-harness probes cannot disagree.
- `ParentLink.precedence` — `manual` > `subagent` > `envInherited` >
  `spawnedProcess`, written down once so everything that has to choose between
  two answers chooses the same way.
- `SessionIdentityPatch` gains `parent`, `parentLink`, `gitRoot`, and
  `worktreePath`. Backward compatible: a patch encoded before they existed
  still decodes, and `isEmpty` accounts for them. `applied(to:)` applies the
  parent by `ParentLink.precedence` rather than last-writer-wins, which is
  what makes `.manual`'s "never overwritten" true whoever emits the patch and
  stops a three-second liveness tick from demoting a logged spawn.
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
