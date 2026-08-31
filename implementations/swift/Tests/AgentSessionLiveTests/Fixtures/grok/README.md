# Grok Build fixtures

One synthetic session, laid out the way `grok` lays a real one out:

```text
grok/session/
├── events.jsonl        the harness's lifecycle log
├── updates.jsonl       the ACP-shaped stream: prompts, prose, tool calls
├── chat_history.jsonl  the model-facing conversation
├── summary.json        identity, rewritten in place
└── signals.json        counters, rewritten in place
```

The directory here is `session/` rather than a percent-encoded cwd and a
session uuid, because these files are read as *record shapes* by the mapper
tests. The tests that need the real
`~/.grok/sessions/<percent-encoded cwd>/<session id>/` layout build it in a
temporary tree, which is what the rest of the suite does too.

Everything is synthetic, written for these tests. The session id is
`77777777-8888-9999-aaaa-bbbbbbbbbbbb`, the working directory is
`/Users/example/code/demo app` — chosen with a space in it, so the
percent-encoding tests have a `%20` to round-trip — and the timestamps run from
`2026-01-01T00:00:01Z` to `2026-01-01T00:00:09.5Z` so that nothing here depends
on today.

## What each file is here to cover

`events.jsonl` (26 lines) — the MCP handshake, including the two failures that
become notes; a `turn_started` for this session and one for a different session
that must be skipped; six `phase_changed` records, three of them the per-token
phases that are dropped even when phase notes are on; an allowed permission and
a denied one; the `tool_started` / `tool_completed` pair the mapper deliberately
ignores; a `turn_ended`; a line of non-JSON and a JSON line with no `type`.

`updates.jsonl` (23 lines) — a prompt, two assistant messages, a thought chunk;
six tool calls covering a local read, a shell command, a backend web search, a
web fetch, an edit with no tool descriptor, and one reached through an MCP
server; `tool_call_update`s that complete, that fail, that are still
`in_progress`, and one that carries no status at all; a `turn_completed` with
its usage block; a `compaction_checkpoint`; a `hook_execution`; a line stamped
with another session's id; and a line of non-JSON.

`chat_history.jsonl` (9 lines) — the `<user_info>` envelope, a
`synthetic_reason` reminder, and the one `user` record that carries a
`prompt_index`, so the three ways `type: "user"` is used are all present.

See `../README.md` for the rules every fixture in this directory follows.
