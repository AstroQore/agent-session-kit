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
.package(url: "https://github.com/AstroQore/agent-session-kit", from: "0.2.0")
```

## Targets

| Target | What it is |
| ------ | ---------- |
| `AgentSessionKit` | Discovery, parsing, deletion planning, the FTS5 session index, and the MCP Unix-socket / stdio transport. |
| `AgentSessionLive` | Live views over the same stores — the unified event model, the state reducer, and the tailing protocols. |

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

`MCPJSON`, `MCPRequest`, `MCPResponse`, `MCPTool`, `MCPResource`, and
`MCPArguments` are here too, so a host writes its tool catalog and its
dispatch and nothing else.

## AgentSessionLive

`AgentSessionKit` answers "what is on disk right now". `AgentSessionLive`
answers "tell me when it changes" — the layer a live board of running agents
is built on. Eight harnesses write eight unrelated formats, so it funnels all
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
`subagentStarted` / `subagentFinished`, `turnEnded`, `usage`, `compaction`,
`sessionEnded`, `liveness`, and `note`. A case exists only where a real store
records the fact.

`SessionSnapshot` carries the derived `SessionState`, the `PendingSet` of what
is still open, turn and tool counters, token totals, and the child sessions a
turn spawned. The reducer is pure and takes its clock as a parameter, so every
transition — including staleness, and a process that dies and comes back — is
testable without waiting.

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
| Grok Bot | — | `~/Library/Application Support/Grok Bot/sand-client-persistence`; the client replicates a cloud conversation on its own schedule, so there is nothing local to tail |

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

### Ingest

`IngestCoordinator` is the only thing a host starts. It owns one
`FSEventsWatcher` over the union of every adapter's roots, a tailer per
discovered source, a debounce in front of each tailer, a safety-net poll
behind it, and a rediscovery pass for sessions that did not exist at start.

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

`JSONLTailer` is the building block six of the eight harnesses share: supply a
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

## Used by

- [Vibe Bar](https://github.com/AstroQore/vibe-bar) — macOS menu-bar app for
  agent quota, usage, and cost. This package was extracted from it.
- Auspex.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
