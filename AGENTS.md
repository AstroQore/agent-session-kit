# AGENTS.md — agent-session-kit

Instructions for coding agents working in this repository. Read this before
touching anything; the conventions here are inherited from Vibe Bar
(`AGENTS.md` § 7 and § 8), which is where this code came from.

## 1. What this is

A dependency-free SwiftPM package that discovers, parses, and indexes the
local session stores of AI coding agents, and serves them over a local MCP
transport. It is a **library**: no UI, no network, no app lifecycle, no
opinion about where the host keeps its data.

It knows about the **usage axis** — the *harness*, the CLI or app that
produced a session on disk. It deliberately knows nothing about the **billing
axis** (quotas, plans, prices, companies). A host that models both adds its
own mapping as an extension in its own module.

## 2. Repository layout

```text
.
├── Package.swift                       # swift-tools-version 6.2, macOS 26
├── RELEASING.md                        # semver policy + how a tag is cut
├── Sources/
│   ├── AgentSessionKit/                # Swift 5 language mode (migration pending)
│   │   ├── AgentSessionKitInfo.swift   # version, repository URL, release-notes URL
│   │   ├── Harness/
│   │   │   └── Harness.swift           # Harness enum + HarnessCatalog. Naming only.
│   │   ├── Sessions/
│   │   │   ├── SessionModels.swift     # SessionProvider, SessionSummary, transcripts, delete plans
│   │   │   ├── SessionParsing.swift    # Provider-agnostic, total parsing primitives
│   │   │   ├── SessionProviderAdapter.swift  # The protocol + the registry
│   │   │   ├── {Claude,ClaudeCowork,Codex,Grok,Cursor,Gemini,Antigravity,GrokBot}SessionAdapter.swift
│   │   │   ├── CodexTitleHydrator.swift          # Titles from Codex's side index
│   │   │   ├── AntigravityConversationIndex.swift
│   │   │   ├── LiveSQLiteReader.swift            # Read a store another process holds open
│   │   │   ├── ProtobufWireReader.swift          # Raw wire decoding, no schema
│   │   │   ├── SessionResumeCommandBuilder.swift
│   │   │   ├── SessionDeleter.swift
│   │   │   ├── SessionIndexService.swift         # Incremental refresh
│   │   │   └── SessionIndexStore.swift           # SQLite + FTS5
│   │   ├── Antigravity/
│   │   │   └── AntigravityGenMetadataReader.swift
│   │   ├── Utilities/
│   │   │   ├── JSONLLineScanner.swift  # O(n) whole-file line walk
│   │   │   ├── JSONLHeadTail.swift     # Bounded head/tail for metadata
│   │   │   ├── RealHomeDirectory.swift
│   │   │   ├── Base32.swift            # RFC 4648 decode, for Grok Bot's filenames
│   │   │   ├── ClaudeCoworkPaths.swift
│   │   │   ├── CodexOriginator.swift
│   │   │   ├── PrivacyPreservingHash.swift
│   │   │   └── KitLog.swift            # Sanitizing logger
│   │   └── MCP/
│   │       ├── MCPJSONRPC.swift        # MCPJSON, MCPRequest, MCPResponse, MCPRPCError
│   │       ├── MCPDescriptors.swift    # MCPTool, MCPResource, MCPToolFailure
│   │       ├── MCPArguments.swift      # Typed tools/call argument decoding
│   │       ├── MCPSocketServer.swift   # AF_UNIX listener, 0600
│   │       └── MCPStdioBridge.swift    # Byte pump for spawn-a-command clients
│   └── AgentSessionLive/               # Swift 6 language mode. Placeholder.
└── Tests/
    ├── AgentSessionKitTests/
    └── AgentSessionLiveTests/
```

Boundary rule: `AgentSessionKit` answers "what is on disk right now" — one
pass, one snapshot, no observers. Anything that watches, debounces, or tails
belongs in `AgentSessionLive`.

## 3. Build and test

```sh
swift build
swift test
```

The suite is hermetic: every test writes its own fixture tree into
`NSTemporaryDirectory()` and tears it down. Nothing reads the real home
directory, and nothing needs a network. If you find yourself wanting either,
the design is wrong.

## 4. Code conventions

- **Explicit paths, always.** Every discovery entry point takes a
  `homeDirectory: String`. `SessionIndexStore` takes a `url`. `MCPSocketServer`
  takes a `socketPath` and an `ensureDirectory` hook. Nothing in this package
  invents a location under `~/`, and no new API may.
- **Never write outside a caller-provided directory.** The one directory this
  package creates is the immediate parent of an index file the caller named.
- **Never follow a symlink**, while enumerating or while deleting. A link
  inside a session store can resolve anywhere, and a delete list must contain
  only paths the provider itself wrote.
- **JSONL parsing must be O(n).** `JSONLLineScanner.forEachLine` for a whole
  file, `JSONLHeadTail` for metadata. A moving cursor, never `removeSubrange`
  in a loop, never `String(contentsOf:)` on a transcript. Metadata extraction
  must stay bounded no matter how large a transcript grew.
- **Parsing is total.** Bad input yields `nil` or `""`, never a throw. A
  single corrupt line must not sink the session list. The two `SessionParseError`
  cases mean "could not read" and "not this provider's shape"; discovery
  treats the second as *skip*.
- **`nil` over invention.** If a log does not record the model, leave it
  `nil`. A wrong model on a row is worse than an empty one, and it would also
  be wrong wherever the host prices it.
- **Storage keys are frozen.** `Harness.rawValue` and
  `SessionProvider.rawValue` land in SQLite and in host caches; renaming one
  silently orphans every stored row.
- **Log through `KitLog`.** File names only — never full paths, never
  transcript text, never anything token-shaped. Use `KitLog.sanitize` for
  anything you cannot vouch for by construction.
- **No dependencies.** Foundation, Darwin, Dispatch, `os.log`, `CryptoKit`,
  `SQLite3`. A package would be more code to audit than the code it replaces.
  Adding one needs an explicit decision, not a convenience.

## 5. Privacy and source-content rules

The repository is AGPL-3.0-only — every commit, file, and diff is meant to be
readable by the world. What may **never** appear in a commit:

- `/Users/<name>` paths, machine hostnames, or real usernames. Fixtures use
  `/Users/example/...`.
- Real organization UUIDs, account ids, workspace ids, OAuth tokens, session
  cookies, or JWTs. Use synthetic values.
- Real transcript content. Every fixture is written by the test that reads it.
- Log strings that could carry a path, a credential, or a user's words.

Before finishing any change, grep the diff for `/Users/`, `@` in an address
shape, and token prefixes.

## 6. Deletion is the dangerous part

Read `SessionDeleter` before changing anything near it.

A `SessionDeletionPlan` is data, not a closure: it carries the paths to
remove, the file to re-parse, and the session id that must still be there.
The deleter re-asserts all of it immediately before removing anything, so a
plan can be built, shown to a user, and executed later without trusting the
summary it came from. It refuses on a symlinked target, on a path that
resolves outside the provider's own roots, on an id mismatch, and on a
validation file it cannot re-read.

`SessionProvider.supportsDeletion` is `false` for AntiGravity, Cursor, and
Claude Cowork because another running app owns those stores, and for Grok Bot
because the conversation itself lives on xAI's servers and this directory is
only what the client replicated. Removing from underneath a live SQLite
handle is how a store gets corrupted rather than emptied. Do not "fix" that.

## 7. Adding a harness

1. `SessionProvider` case + `displayName` (via `HarnessCatalog`) +
   `defaultHarness` + an honest `supportsDeletion`.
2. An adapter. `roots(homeDirectory:)` is both the discovery scope and the
   deleter's containment fence — keep it exactly as narrow as the store is.
3. Register in `SessionProviderRegistry.standard`.
4. Tests over a synthetic temp tree: metadata, transcript, deletion plan, and
   the malformed-input case.
5. README table row, including what the format genuinely cannot answer.

## 8. Commits

Conventional-commit subjects (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`,
`chore:`); branches use the same prefixes (`feat/`, `fix/`, …), never an agent
name. Work inside a git worktree under `.agents/worktrees/<branch>` rather
than the user's main tree.

End every commit message with a `Co-Authored-By:` trailer naming the actual
participants.

## 9. Releasing

[RELEASING.md](RELEASING.md) is the procedure and the semver policy. Read it
before touching a tag, a version number, or `.github/workflows/release.yml`.
The parts that constrain ordinary changes:

- **The version constant moves in the release commit, not before.**
  `AgentSessionKitInfo.version` is the only version a statically linked host
  can read — there is no bundle, no `Info.plist`, and no dylib once this code
  is compiled in. `AgentSessionKitInfoTests` pins it to the newest
  `## [X.Y.Z]` section of `CHANGELOG.md`, so a feature branch that bumps one
  without the other fails `swift test`. Feature work adds to
  `## [Unreleased]` and leaves the constant alone.
- **Tags are bare `X.Y.Z`.** No `v` prefix; the tag string is the version
  string. Pushing one runs `release.yml`, which re-verifies tag ↔ constant ↔
  changelog, builds, tests, and publishes a GitHub Release whose notes are
  that changelog section. It refuses rather than repairs.
- **A published tag never moves.** If a release run fails, fix forward on
  `main` and cut the next version. Re-pointing a tag makes two source trees
  answer to one version, which is exactly what a pinned dependency exists to
  prevent.
- **A release is not a delivery.** Hosts link this package statically and pin
  it `exact:`. A new tag reaches a user when the host bumps its pin and ships
  a build — never on its own. Say it that way in any UI or note that mentions
  a newer version.
