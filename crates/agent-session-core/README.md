# agent-session-core

Cross-platform Rust lane of `agent-session-kit`. The Swift package (repo
root) and this crate are peer implementations of the same session-reading
semantics; the repository is the shared source of truth for both.

First slice — everything a cross-platform host (e.g. `vibe-bar-desktop`)
needs to render sessions without depending on the Swift implementation:

- **`index`** — read-only access to a host-maintained `session_index.sqlite3`
  (schema `user_version = 5`): recent-session listing, trigram-FTS /
  `LIKE` search, and message-excerpt paging. Opens `SQLITE_OPEN_READONLY`,
  fails closed on any other schema version, and never creates, migrates,
  prunes, or rebuilds — index mutation stays with the index owner.
- **`discovery`** — lightweight filesystem discovery for Codex
  (`~/.codex/sessions`, `~/.codex/archived_sessions`) and Claude Code
  (`~/.claude/projects`, `~/.config/claude/projects`) session logs: head
  lines only, symlinks never followed, newest first.
- **`transcript`** — tolerant JSONL transcript paging for Codex and Claude
  Code. Malformed or unknown lines are skipped, never fatal.
- **`resume`** — mirror of the Swift `SessionResumeCommandBuilder`: same
  commands, same per-provider id charsets, same refusal semantics for
  Cowork / Cursor / Grok Bot / AntiGravity-IDE sessions.
- **`jsonl`** — bounded O(n) JSONL reading (moving cursor, 4 MB line cap).

Like the Swift package, this crate takes every path explicitly, opens no
sockets, spawns no processes, and writes nothing.

```rust
use agent_session_core::index::{SessionIndexReader, SessionListFilter};

let reader = SessionIndexReader::open(std::path::Path::new(
    "/Users/example/.vibebar/session_index.sqlite3",
))?;
let recent = reader.list(&SessionListFilter { limit: 20, ..Default::default() })?;
```

## Contracts mirrored from the Swift implementation

| Contract | Value |
| --- | --- |
| Index schema version | `PRAGMA user_version = 5` (any other value ⇒ refuse) |
| Provider raw values | `claude`, `claudeCowork`, `codex`, `grok`, `cursor`, `gemini`, `antigravity`, `grokBot` |
| Harness display names | `Codex`, `ChatGPT Work`, `Claude Code`, `Claude Cowork`, `Gemini CLI`, `AntiGravity`, `Grok Build`, `Cursor`, `Grok Bot` |
| Index timestamps | Unix epoch seconds (INTEGER) |
| FTS query | one double-quoted phrase, `""` escaping; needles < 3 chars use escaped `LIKE` |
| Resume validation | uuid charset for claude/codex/cursor/antigravity/grokBot ids; `[A-Za-z0-9._-]` for grok/gemini; max 200 chars |
