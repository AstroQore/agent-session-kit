# agent-session-kit

Reads the session stores AI coding agents leave on your machine, and serves
them over MCP. **Two implementations, one set of semantics:** a Swift package
for macOS hosts and a Rust crate for cross-platform ones.

Every coding agent keeps a local record of what you asked it — Codex writes
rollout JSONL, Claude Code writes transcript JSONL, Cursor and AntiGravity
write SQLite databases another process holds open. Each one has its own
layout, its own idea of a "session id", and its own way of spelling a
timestamp. This repository hides all of that behind one adapter protocol, a
searchable index, and a local MCP transport.

No third-party dependencies in either lane beyond the system SQLite.

```swift
// Swift — macOS 26, Swift 6.2
.package(url: "https://github.com/AstroQore/agent-session-kit", exact: "0.7.0")
```

```toml
# Rust — macOS, Linux, Windows
agent-session-core = { git = "https://github.com/AstroQore/agent-session-kit", tag = "0.7.0" }
```

`exact:` while the package is `0.x` — see
[Versioning and releases](#versioning-and-releases).

## Layout

```text
Package.swift                 SwiftPM entry point
Cargo.toml                    Cargo workspace entry point
contracts/                    Semantics both lanes are checked against
implementations/swift/        Sources/ + Tests/
implementations/rust/         crates/
```

Both manifests stay at the repository root, so a consumer's git URL, pin, and
`import AgentSessionKit` are unaffected by the layout — and neither language's
tooling needs a non-default working directory.

The two lanes are peers, not a primary and a port. Neither is generated from
the other, which is why anything they must agree on lives in `contracts/` with
a test on each side. Today that is the session index schema
(`contracts/storage/session-index-v5.sql`): the Swift writer is checked to
create exactly those objects, and the Rust reader is checked to open a database
built from that file. Add to `contracts/` whenever a new fact has to hold in
both languages; a change there is a coordinated change plus a kit minor bump.

## What each lane provides

**Swift** (`implementations/swift`, macOS 26, Swift 6.2)

| Target | What it is |
| ------ | ---------- |
| `AgentSessionKit` | Discovery, parsing, deletion planning, the FTS5 session index, and the MCP Unix-socket / stdio transport. |
| `AgentSessionLive` | Live views over the same stores — the unified event model, the state reducer, and the tailing protocols. |

**Rust** (`implementations/rust`, macOS / Linux / Windows)

| Crate | What it is |
| ----- | ---------- |
| `agent-session-core` | Read-only session index access, lightweight Codex and Claude Code discovery, tolerant JSONL transcript paging, and the resume command builder. |

The Rust lane is deliberately the smaller of the two: it covers what a
cross-platform host needs to render sessions without the Swift runtime. It
never writes the index — schema mismatch is refused, never rebuilt — because
the writer is the host that owns the file.

## Architecture

Two targets, one boundary. `AgentSessionKit` answers "what is on disk right
now" — one pass, one snapshot, no observers: discovery, parsing, the FTS5
index, deletion planning, and the MCP transport. `AgentSessionLive` is
everything that *watches*: FSEvents, incremental tailing, the unified event
model, and the state reducer. It depends on the Kit; the Kit knows nothing
about it. If a type debounces, polls, or holds a cursor, it belongs in Live.

The package knows about the **usage axis** — the harness that produced a
session — and deliberately nothing about the **billing axis** (quotas,
plans, prices, companies). A host that models both writes that mapping in
its own module.

There are **no third-party dependencies**: Foundation, Darwin, Dispatch,
`os.log`, `CryptoKit`, and the system SQLite. That is a deliberate
constraint rather than an accident — a host links this package statically
into a signed application bundle, and every dependency here would become a
dependency it has to audit, license, and ship. Nothing in here opens a
network socket, spawns a helper, or invents a path under `~/`; every entry
point takes the home directory it should read.

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
| Grok Bot | `~/Library/Application Support/Grok Bot/sand-client-persistence` | ✅ | ❌ the run happens server-side | ❌ a cloud cache |

Where a ⚠️ appears the log genuinely does not carry the value — an aborted
Cursor conversation records no model name at all, and old Gemini CLI chats
predate the per-turn `model` field. Those stay `nil`. A model is never
inferred from the vendor's "usual" one; a wrong model on a row is worse than
an empty one. Grok Bot's ❌ is the stronger statement: the conversation runs
on xAI's servers and the client's cache records no model, no token counts,
and no cost for anyone to read.

Four providers are listed and readable but never deletable, because another
running app — or, for Grok Bot, a server — owns the store.
`SessionProvider.supportsDeletion` says so up front, and the adapters fail
closed with `SessionDeleteError.providerIsReadOnly`.

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

The default client cap is 64; pass `maximumConnections:` to tune it. Hosts
whose stdio clients reconnect after EOF may also opt into idle reclamation
with `idleTimeout:`; it is disabled by default because the library cannot
assume every client respawns a deliberately closed child. `clientConnections` and
`onConnectionsChange` expose only a connection id, peer pid, connected time,
and last activity. A host can call `disconnectClient(id:)` to close one socket
safely. A client beyond the configured cap receives a framed JSON-RPC
capacity error instead of a silent close.

`MCPStdioBridge` runs the same binary as a plain stdio MCP server that pumps
bytes to that socket, which is how MCP clients that spawn a command reach a
running GUI app:

```swift
let bridge = MCPStdioBridge(
    config: MCPStdioBridgeConfig(
        flag: "--mcp-stdio",
        envKey: "MYAPP_MCP_SOCKET",
        // A closure, resolved lazily, so a default that depends on the real
        // home directory is looked up when the socket is actually needed —
        // not baked in at config-build time.
        defaultSocketPath: { defaultSocket }
    )
)
if bridge.isRequested() { exit(bridge.run()) }
```

The static functions this wraps (`MCPStdioBridge.isRequested`,
`.socketPath`, `.run`, each taking `config` explicitly) are still there
unchanged, for callers that would rather not hold an instance.
If the listener is full, the bridge writes the configured
`connectionLimitMessage` to stderr and exits with
`MCPStdioBridge.ExitCode.connectionLimit` (2); it does not report a successful
empty session.

`MCPJSON`, `MCPRequest`, `MCPResponse`, `MCPTool`, `MCPResource`, and
`MCPArguments` are here too, so a host writes its tool catalog and its
dispatch and nothing else.

## AgentSessionLive

`AgentSessionKit` answers "what is on disk right now". `AgentSessionLive`
answers "tell me when it changes" — the layer a live board of running agents
is built on. Nine harnesses write nine unrelated formats, so it funnels all
of them into one vocabulary and lets everything downstream speak only that.

```swift
import AgentSessionLive

// A session is a harness plus that harness's own id.
let key = SessionKey(harness: .claudeCode, sessionID: "3f2b…")   // "claudeCode:3f2b…"

// Adapters turn source records into one harness-agnostic event type.
let event = AgentEvent(
    session: key,
    timestamp: lineDate,
    kind: .toolCallStarted(id: "toolu_1", name: "Bash", kind: .shell, target: "swift test")
)

// A pure reducer folds events into the row a board renders.
let reducer = SessionStateReducer(staleAfter: 90)
snapshot = reducer.reduce(snapshot, event: event)

snapshot.state.label      // "Tool: Bash"
snapshot.state.sortRank   // blocked sessions sort above busy ones
snapshot.isStale          // working, alive, and silent for too long
```

`AgentEventKind` is the whole vocabulary: `sessionStarted`, `identityUpdated`,
`userPrompt`, `turnStarted`, `thinking`, `assistantText`, `toolCallStarted` /
`toolCallFinished`, `permissionRequested` / `permissionResolved`,
`subagentStarted` / `subagentFinished`, `turnEnded`, `usage`, `contextUsage`,
`compaction`, `quota`, `sessionEnded`, `liveness`, and `note`. A case exists
only where a real store records the fact.

`SessionSnapshot` carries the derived `SessionState`, the `PendingSet` of what
is still open, turn and tool counters, token totals, how full the context
window is, the child sessions a turn spawned, and a `SessionBrief`. The reducer
is pure and takes its clock as a parameter, so every transition — including
staleness, and a process that dies and comes back — is testable without
waiting.

### The context gauge

`SessionSnapshot.contextUsage` is the `/context` panel, not the bill: a level
rather than a total, and the same level on every row. `used` is **the tokens
that were in the model's context when it was last called** — the whole prompt,
cached prefix included, and the reply the model just generated excluded,
because that lands in the *next* call's input.

```swift
snapshot.contextUsage?.used      // 898_800
snapshot.contextUsage?.window    // 1_000_000
snapshot.contextUsage?.fraction  // 0.8988 — never clamped; overfull reads overfull
snapshot.contextUsage?.source    // .derived — say so in the UI
snapshot.compactions             // 2
snapshot.quota?.usedPercent      // 43.2, from Codex's own rate_limits
```

| Harness | Read from | `source` |
| ------- | --------- | -------- |
| Claude Code, Claude Cowork | `message.usage` input + both cache counters; the window from `ModelContextWindows` | `derived` |
| Codex, ChatGPT Work | `token_count`: `last_token_usage.input_tokens` and `info.model_context_window` | `measured` |
| Grok Build | `signals.json`: `contextTokensUsed` and `contextWindowTokens` | `measured` |
| Cursor, AntiGravity, Grok Bot, Gemini CLI | nothing on disk answers it | `nil` |

Claude Code computes both its window size *and* its category breakdown
(messages, system tools, skills, MCP tools, memory files) in-process and writes
neither to disk, so the fill is real and the denominator is a lookup —
`ModelContextWindows`, which a host can extend and which answers `nil` rather
than guessing for a model it has not heard of. That is what `source` is for. A
model the table misses still reports a fill with no window: "421k used" is
worth showing, a wrong denominator is not.

`SessionQuota` is the other half of what Codex writes beside its token counts —
`used_percent`, when the window resets, the plan name. Read off the rollout;
nothing here asks a network what a limit is.

`SessionBrief` is the other half of a board row: what the session was *asked*
to do (`firstPrompt`), what was asked last, the last thing the model said in
prose, and when a turn last closed. It is folded from `userPrompt`,
`assistantText`, and `turnEnded`, and it drops the things a person did not
type — Claude Code's `<command-name>` slash-command echoes and
`<local-command-…>` hook output, `<system-reminder>` injections, Codex's
`<environment_context>` and `<user_instructions>` — including the ones a
preview truncated mid-block.

```swift
snapshot.brief.firstPrompt      // "Add a regression test for the JSONL tailer."
snapshot.brief.followUpPrompt   // the latest one, when it says something new
snapshot.brief.latestAssistant  // "The build needs the Testing module wired in first."

// "How do I get back to this one?" — nil for the harnesses with no CLI.
SessionResume.resumeCommand(for: snapshot.identity)
// "cd '/Users/example/code/demo' && codex resume 1111…"
SessionResume.availability(for: snapshot.identity).reason
// the sentence for a disabled menu item
```

Adapters implement `SourceAdapter` (discovery, watch roots, liveness probing)
and `SessionTailer` (`poll()` for the steady state, `seedFromTail(maxBytes:)`
for a bounded cold start), resuming from a persisted `SourceCursor`. Text
entering an event goes through `EventText`, and anything read from the process
table goes through `ArgvSanitizer`.

### Live adapters

| Harness | Adapter | Store |
| --- | --- | --- |
| Claude Code | ✅ `ClaudeLiveAdapter` | `~/.claude/projects/**/*.jsonl`, `~/.claude/sessions` |
| Claude Cowork | ✅ `ClaudeCoworkLiveAdapter` | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/**/*.jsonl`; liveness via the Claude.app helper's `CLAUDE_CODE_SESSION_ID` |
| Codex | ✅ `CodexLiveAdapter` | `~/.codex/sessions/**/rollout-*.jsonl`, `~/.codex/archived_sessions`; liveness via `~/.codex/thread-writer-locks/<id>.lock` |
| ChatGPT Work | ✅ `CodexLiveAdapter` | the same tree, keyed apart by `session_meta.originator == "codex_work_desktop"` |
| Grok Build | ✅ `GrokLiveAdapter` | `~/.grok/sessions/<percent-encoded cwd>/<id>/{events,updates}.jsonl`; liveness via `~/.grok/active_sessions.json` and the per-file writer locks |
| Gemini CLI | — | `~/.gemini/tmp/*/chats` |
| AntiGravity | ✅ `AntigravityLiveAdapter` | `~/.gemini/antigravity{-cli,}/conversations/*.db`; state from the SQL columns plus a shallow `step_payload` decode; liveness via `presence/<id>.lock` |
| Cursor | ✅ `CursorLiveAdapter` | `~/.cursor/chats/**/store.db` + `~/.cursor/projects/<slug>/agent-transcripts`; liveness via `cursor-agent-worker-*.pid` and the store's WAL |
| Grok Bot | ✅ `GrokBotLiveAdapter` | `~/Library/Application Support/Grok Bot/sand-client-persistence/<base32(key)>.blob`; the roster slice supplies the name and the needs-you flag; liveness via the `Grok Bot` process and `~/.grokbot/local-exec-supervisor.json` |

```swift
let adapter = ClaudeLiveAdapter()
for source in try await adapter.discover(home: home, activeSince: .now - 3600) {
    let tailer = try adapter.makeTailer(source, cursor: cursors[source.key])
    for event in try await tailer.poll() {
        snapshot = reducer.reduce(snapshot, event: event)
    }
}
```

`ClaudeRecordMapper` is the whole translation, and it is pure: one transcript
line in, zero or more events out, no clock of its own. `ClaudeLiveAdapter`
owns everything around it — which files are worth tailing, what can be known
about a session before reading it, and whether its process is still there.

A session counts as active when it was written to since the cutoff *or* when
`~/.claude/sessions` says a process is driving it; a session that has sat at a
prompt for an hour is the most live thing on the machine, and a cutoff alone
would drop exactly the rows a board exists to show. That directory is also
what liveness rests on, since Claude Code holds no lock on its transcript: the
entry appears when the process starts and is removed when it exits.

Subagents come back as sessions of their own, keyed
`claudeCode:<session id>/agent-<agent id>`. The two halves are recorded in two
files that share nothing but a tool-use id — the parent logs the `Task` call
and never the child's `agentId`, the child's meta file logs the tool-use id —
so `ClaudeSubagentLinker` does the join at discovery and the parent's tailer
reports `subagentStarted` / `subagentFinished` on the parent's stream.

`ClaudeCoworkLiveAdapter` reads the same format from Claude.app's own
container, where the local agent runs the app drives itself are written.
Discovery and seeding are literally the same code — `ClaudeSourceBuilder`,
parameterised by harness — because the transcripts are byte-identical; what
differs is that the tree is nested several levels deeper behind a hidden
`.claude` directory, and that no `~/.claude/sessions` entry exists for a Cowork
run. Liveness therefore comes from the process that launched it: a binary under
`/Applications/Claude.app` whose environment carries this session's
`CLAUDE_CODE_SESSION_ID`, falling back to the transcript's own freshness when
that environment cannot be read. The keys are `claudeCowork:<session id>`, not
Claude Code's, because a board that folded the two together would attribute the
app's background work to whatever a person was doing in a terminal.

`CodexLiveAdapter` covers every Codex surface that writes into that one tree —
CLI, VS Code, desktop, `codex exec`, and the sub-agents any of them spawn.
`CodexRecordMapper` is pure and static, so a rollout line maps to events with
no adapter, no clock, and no I/O involved. A held writer lock overrides the
discovery window: a thread opened last month and still running is found
whatever its rollout's mtime says, and the kernel drops that lock however the
process ended.

One of those surfaces is a harness of its own. `originator ==
"codex_work_desktop"` is ChatGPT Work mode in the desktop app, so discovery
keys those rollouts `chatgptWork:<thread id>` through `CodexOriginator` — the
same mapping the on-disk index uses — and everything downstream follows the
source's key. Anything unrecognised, including a rollout with no header at all,
stays on Codex rather than being invented as ChatGPT Work usage. Because one
adapter now answers for two harnesses, `SourceAdapter` grew
`handledHarnesses` (default `[harness]`), and `LivenessResolver` indexes by
that rather than by the primary harness; without it every ChatGPT Work session
would come back `unknown`.

`GrokLiveAdapter` is the first one whose session is several files rather than
one. `GrokSessionTailer` runs a `JSONLTailer` per file and merges them by the
source's own timestamp into a single stream with a single sequence, and the
`SourceCursor` a host persists is a `.composite` keyed by path, so one file
rotating re-seeds that file alone. `events.jsonl` carries the turn boundaries
and the permission prompts, `updates.jsonl` carries the prompts, the prose, and
every tool call with the ids to pair them by, and `GrokRecordMapper` documents
which of the two each fact is read from — `chat_history.jsonl` is named on the
source so a watcher wakes on it, but nothing is read from it, because
everything in it is in `updates.jsonl` too and stamped.

Two Grok-specific things a host should know. The directory a session lives in
*is* its working directory, percent-encoded, so `GrokSessionsPath` decodes it
exactly rather than guessing — unlike Claude Code's lossy project directories.
And a permission prompt is recorded with a tool name and no id at all, so the
mapper mints `perm:<tool name>`, which pairs a request with its answer at the
cost of collapsing two simultaneous prompts for the same tool into one.

`CursorLiveAdapter` is the first adapter over a database rather than a log.
A session's `primaryPath` is its `store.db`, which is what makes the
coordinator register the `-wal` and `-shm` siblings — Cursor holds the store
open in WAL mode, so a whole turn can land in `-wal` and only reach the `.db`
at a checkpoint minutes later.

Inside it, `latestRootBlobId` in the `meta` table is the head of a
content-addressed graph, and it changes exactly once per turn: a poll that
finds it unchanged returns without fetching a blob. When it does move,
`CursorStoreReader` walks breadth-first from the new head with the previous
walk's visit set in hand, so only genuinely new blobs are fetched — the
conversation's other messages keep the ids they had, because the store is
content-addressed. A cursor persists `"<head>|<anchor>"`, where the anchor is
the id of the last message emitted; after a relaunch that is enough to find the
place again in one traversal, and only the messages past it are parsed.

Two files carry one Cursor session and each owns what it is the authority on.
The store has the tool calls, the reasoning, the model, and the full text of
everything, and no notion of a turn ending. The thin transcript at
`~/.cursor/projects/<cwd slug>/agent-transcripts/<agent id>/<agent id>.jsonl`
— written only when a `cursor-agent` CLI drove the session — has turn
boundaries and nothing else. So the thin transcript owns `userPrompt` and
`turnEnded`, the store owns everything with detail in it, and an agent started
inside the IDE, which has no transcript, gets `userPrompt` from the store
instead. Emitting it from both would count every turn twice.

`AntigravityLiveAdapter` is the odd one out, because AntiGravity is the one
store that does not append. A conversation is a SQLite database whose `steps`
table is *rewritten*: a tool call is a single row whose `status` column walks
`PENDING → RUNNING → DONE` in place. So the tailer diffs rather than walks —
each poll re-reads the rows still open behind its cursor and emits only the
transitions, which is the only way `toolCallStarted` and `toolCallFinished`
come out exactly once each. Most of a row's state is in the columns; the rest
comes from a shallow, tolerant decode of the undocumented `step_payload`
protobuf, whose field numbers and 118-value step-type table were read out of
the `agy` binary's own descriptors rather than guessed. Both roots are covered
— `antigravity-cli` for the command line, `antigravity` for the IDE — and
discovery unions the CLI's `conversation_summaries.db` with a walk of the
conversation directories, because that index routinely names a fraction of the
databases actually on disk.

`GrokBotLiveAdapter` is the other one that does not append, and the only one
whose session is not on this machine at all. A conversation is a JSON document
the desktop client rewrites whole, named after the base32 of its own key:
entries land at the end of an array and an entry already in it is edited in
place while its reply streams, so there is no offset to resume from and the
tailer diffs the file against itself. The cursor is the id of the last entry
consumed, which is what survives a rewrite. A streaming entry produces
`thinking` and nothing else — its text is a prefix of what it will hold a
second later — and the words come out of the read that finds `isStreaming`
cleared. The roster slice beside it is an auxiliary path rather than a second
source, because it carries the two facts the conversation does not: the bot's
name, and `awaitingUserResponse`, the client's own "this one is blocked on
you" flag, which becomes a `permissionRequested` with no tool. Liveness is
about the *client*: no `Grok Bot` process and no fresh supervisor heartbeat
ends every conversation at once, while a running client with a quiet
conversation is `unknown` however long the quiet has lasted. Nothing in
`~/.grokbot` is read but the heartbeat, and that directory is not watched.

### Ingest

`IngestCoordinator` is the only thing a host starts. It owns one
`FSEventsWatcher` over the union of every adapter's roots, a tailer per
discovered source, a debounce in front of each tailer, a safety-net poll
behind it, and two ways of noticing a session that did not exist at start.

A change to a path something already tails polls that tailer. A change to a
path nothing tails goes to the adapters whose declared `watchRoots` contain
it — and to no others — as `discover(home:activeSince:under:)` over the one
directory it happened in. That containment test is load-bearing:
`mightBeSessionFile` is a rule about names, so without it Codex's "any
`*.lock` could be a thread" claims every writer lock Grok rewrites, and
Cursor's "any `*.jsonl`" claims every Claude Code transcript. A path no
adapter claims costs nothing at all. Behind that, every adapter sweeps its
whole store once a minute as the safety net for a notification that never
arrived — and that sweep is the only pass that can drop a source, because
"nobody discovered this" needs somebody to have looked everywhere.

The narrowing is a default, not a requirement: an adapter that does not
implement `discover(home:activeSince:under:)` sweeps, which is correct and
merely as expensive as sweeping always was.

```swift
let coordinator = IngestCoordinator(
    adapters: [ /* one per harness */ ],
    home: home,
    cursorStore: JSONFileCursorStore(url: cursorsURL)
)
let (events, notices) = await coordinator.start()

for await event in events {
    snapshot = reducer.reduce(snapshot, event: event)
}
```

`notices` is the diagnostic channel — `sourceDiscovered`, `sourceDropped`,
`tailerError`, `watcherRestarted` — and a host may ignore it. Timings live in
`IngestConfiguration`. Nothing inside the pipeline drops an event; the only
place a drop can happen is the stream's buffering policy, which
`TailerBackpressure` documents.

Cursors are saved on an interval, and only for the sources that moved: the
coordinator calls `SourceCursorStore.save(changed:all:)` with what it read
since the last save, and the save is skipped entirely when nothing did. The
default implementation writes `all`, so a store that can only replace needs no
changes and behaves as it always has; a store that can write a subset should
implement the method and apply `changed` in one transaction. Shutdown writes
everything, which is what makes a source that was registered and never
produced an event resume rather than re-seed.

`JSONLTailer` is the building block six of the nine harnesses share: supply a
`(Data, JSONLLineRef) -> [AgentEvent]` decoder and inherit rotation and
truncation detection, partial-line buffering, byte-offset cursors, and bounded
cold-start seeding. `SQLiteChangeWatcher` covers the two harnesses that keep a
database open instead, where the file that moves during a turn is the `-wal`
and not the `.db`. A watch root that does not exist yet is still watched —
`FSEventsWatcher` subscribes to the nearest existing ancestor and re-arms when
the root appears, so a harness installed after launch is picked up without a
restart.

### Liveness

The one fact no log records: a transcript ends identically whether the harness
exited, was killed, or is still thinking. `ProcessTable` reads `libproc` and
`sysctl KERN_PROCARGS2` — same-uid processes only, argv and environment
sanitized, the snapshot cached so a tick costs one read — and `LockFileProbe`
asks the kernel who holds an advisory lock on a file. `LivenessResolver`
combines each adapter's own probe with a generic `(pid, startTime)` check,
because pids are recycled and the pair is the identity, and emits `liveness`
events only when the answer changes.

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
- **Logging goes through `os.Logger`**, under subsystem
  `com.astroqore.AgentSessionKit` (one category per logging site). Hosts can
  filter to just this subsystem in Console.app or `log stream
  --predicate 'subsystem == "com.astroqore.AgentSessionKit"'`. It never logs
  paths, transcript bodies, or secrets — see `KitLog` above.

Test fixtures use `/Users/example` and synthetic ids. Never commit a real
username, path, org id, or token.

## Versioning and releases

Bare semver tags, no `v` prefix — `0.1.0`, `0.2.0`, `0.3.0`. While the
package is `0.x`, a **minor** bump carries anything a caller could trip over
(a renamed API, a new provider case, a bumped `eventSchemaVersion`, a changed
storage key) and a **patch** carries fixes and internals only. Pin `exact:`.

```swift
.package(url: "https://github.com/AstroQore/agent-session-kit", exact: "0.7.0")
```

Every build knows which version it is:

```swift
import AgentSessionKit

AgentSessionKitInfo.version                   // "0.7.0"
AgentSessionKitInfo.bundledReleaseNotesURL    // .../releases/tag/0.7.0
AgentSessionKitInfo.repositoryURL
```

That constant exists because this package is linked statically — once it is
compiled into a host binary there is no bundle, no `Info.plist`, and no
dylib left to read a version off. It is pinned by a test to the newest
section of [CHANGELOG.md](CHANGELOG.md), so the two cannot drift.

Pushing a `X.Y.Z` tag runs `.github/workflows/release.yml`, which re-checks
the tag against the version constant and the changelog before publishing a
GitHub Release with that changelog section as its notes. The full procedure,
the semver policy, and what to do when a release goes wrong are in
[RELEASING.md](RELEASING.md).

One thing worth being clear about, because it is easy to imply otherwise: a
release here reaches *users* only when a host bumps its pin and ships a build
of its own. Nothing updates in place.

## Used by

**Swift lane.**

- [Vibe Bar](https://github.com/AstroQore/vibe-bar) — macOS menu-bar app for
  agent quota, usage, and cost. This package was extracted from it, and Vibe
  Bar pins it `exact:` and compiles it into the app; its Settings › System
  pane shows the bundled `AgentSessionKitInfo.version`. It uses
  `AgentSessionKit` for the session index, transcripts, deletion planning and
  the MCP transport.
- [Auspex](https://github.com/AstroQore/auspex) — a macOS app that watches the
  agent sessions running on one machine. It is the only consumer of **both**
  products: `AgentSessionKit` for what is on disk, and `AgentSessionLive` for
  the tailing, liveness and event pipeline that turns it into a live view.

**Rust lane.**

- [Vibe Bar Desktop](https://github.com/AstroQore/vibe-bar-desktop) — the
  cross-platform client of the same product, on Windows and Linux as well as
  macOS. It depends on `agent-session-core` for read-only index access,
  Codex/Claude Code discovery, transcript paging and resume commands, so both
  Vibe Bar clients read sessions by one set of rules rather than two.

Vibe Bar and Auspex ship their own release trains and bump the pin
independently; nothing here is loaded at runtime, so a kit release reaches a
user only inside the next build of the app that consumes it.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
