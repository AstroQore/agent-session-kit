# Fixtures

Sample source records for the `AgentSessionLive` adapters, one directory per
harness:

```text
Fixtures/
├── claude/        # Claude Code transcript JSONL
├── codex/         # Codex rollout JSONL
├── cursor/        # Cursor store.db rows, exported as JSON
├── grok/          # Grok Build events.jsonl / updates.jsonl
└── antigravity/   # AntiGravity conversation rows
```

Empty today. The adapters land in M1/M2 and bring their own samples with
them; the layout is fixed now so that nobody has to invent one later.

## The rules

This repository is AGPL-3.0-only: every file, commit, and diff is meant to be
readable by the world, and a session transcript is the most personal thing on
a developer's machine. A fixture is a *synthetic* record that happens to have
the shape of a real one.

- **No real transcript content.** Write the prompts and replies yourself.
  "add a test for the reducer" is a fine prompt; whatever you actually asked
  an agent this morning is not.
- **`/Users/example` only.** Never a real username, home directory, hostname,
  or machine name. Repository paths are `/Users/example/code/<something>`.
- **No credentials, ever.** No API keys, OAuth tokens, session cookies, JWTs,
  or `Authorization` headers — not even expired ones, and not even redacted
  ones that keep a recognisable prefix. If a fixture needs to prove that
  `ArgvSanitizer` works, invent the string: `crsr_0123456789abcdef`.
- **Synthetic ids.** UUIDs like `11111111-2222-3333-4444-555555555555`, not
  ids copied from a real store. No organization, account, or workspace ids.
- **As small as the test needs.** A tailer test wants five lines with the
  right shape, not a 4 MB transcript. Keep a fixture readable in a diff.
- **Timestamps from a fixed epoch.** Tests pin their own clock; a fixture
  that says "now" makes a suite that fails next year.

Before committing, grep the diff for `/Users/` followed by anything but
`example`, for an `@` in an address shape, and for the token prefixes
`sk-`, `crsr_`, `xai-`, `ghp_`, `glpat-`, `eyJ`.

## Tests that write their own tree

Most of the suite does not use this directory at all: `AgentSessionKit`'s
convention is that a test builds its fixture tree into `NSTemporaryDirectory()`
and tears it down, and the live tests follow it. A file belongs here only when
it is a *record shape* worth reading — a rollout item with an unusual field, a
Cursor blob whose protobuf framing matters — rather than a tree worth walking.
