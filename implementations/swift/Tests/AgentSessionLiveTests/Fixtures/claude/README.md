# Claude Code fixtures

Synthetic transcripts in the shape Claude Code 2.1.229 writes. Every prompt,
reply, path, and id here was invented for the test — the *shapes* were checked
against real transcripts, the content never came from one. See the rules in
`Fixtures/README.md`.

| File | Stands in for |
| --- | --- |
| `session.jsonl` | `~/.claude/projects/-Users-example-code-demo/11111111-….jsonl` |
| `subagent.jsonl` | `…/11111111-…/subagents/agent-a1b2c3d4e5f60718.jsonl` |
| `subagent.meta.json` | `…/subagents/agent-a1b2c3d4e5f60718.meta.json` |
| `session-pid.json` | `~/.claude/sessions/4242.json` |

Tests that need the real directory layout build it into a temporary tree and
copy these files into place; the flat layout here keeps them readable in a
diff.

## What `session.jsonl` covers

30 records, one of every `type` the adapter has an opinion about:

- `queue-operation` — a prompt queued before the session wrote anything.
- `user` with string content — the one human prompt, long enough that its
  `userPrompt` preview truncates and its `textBody` does not.
- `user` with `isMeta: true` — an injected skill preamble. Looks like a
  prompt, is not one, and must produce no `userPrompt`.
- `user` with `tool_result` blocks — eleven of them, one per tool call,
  including one `is_error: true`, one with a `toolUseResult` sidecar carrying
  `stdout`/`stderr`, and several whose sidecar is structured data the mapper
  ignores in favour of the block's own content.
- `assistant` — `thinking`, `text`, and `tool_use` blocks; `Bash`, `Read`,
  `Edit` (twice), `Write`, `Grep`, `WebFetch`, `TodoWrite`, `Skill`, `Task`,
  and one `mcp__demo_server__lookup_symbol`, so all nine `ToolKind` cases
  appear. Every record carries `message.usage`; the last carries
  `stop_reason: "end_turn"` and closes the turn.
- `worktree-state` — the session moves into a worktree, changing both `cwd`
  and `gitBranch` mid-transcript.
- `system` / `subtype: "compact_boundary"` — context was compacted.
- `attachment`, `mode`, `pr-link`, `file-history-snapshot`, `last-prompt` —
  the record types the adapter deliberately drops.
- `custom-title` — the pinned title, written last, as `/title` writes it.

`subagent.jsonl` is the child `Task` call `toolu_task01` spawned: four records
carrying `agentId`, `isSidechain: true`, and the *parent's* `sessionId`, ending
in an `end_turn` so the linker has a finish to report.

## Regenerating

These were written by hand rather than exported. Editing one means editing the
file; there is no generator to re-run, and there deliberately is no path from a
real transcript to this directory.
