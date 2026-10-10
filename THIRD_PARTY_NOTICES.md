# Third-Party Notices

`agent-session-kit` is licensed under the GNU Affero General Public License
v3.0 only, and has **no third-party package dependencies**. It links only
against the platform: Foundation, Darwin, Dispatch, `os.log`, `CryptoKit`, and
the system SQLite (`SQLite3`). One third-party component is compiled in from
vendored source, listed below.

## Zstandard (vendored)

`implementations/swift/Sources/CZstd/lib/` is an unmodified copy of the
decompression half of **Zstandard** — `lib/zstd.h`, `lib/zstd_errors.h`,
`lib/common/` and `lib/decompress/` — from
[facebook/zstd](https://github.com/facebook/zstd) release **v1.5.7**
(commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`). No compressor, no legacy
format support, and no assembly is built (`ZSTD_DISABLE_ASM`,
`ZSTD_LEGACY_SUPPORT=0`). It exists so that a Codex rollout the CLI has
compressed to `.jsonl.zst` can be read; macOS ships neither a zstd library
nor its headers.

Zstandard is dual-licensed under the BSD 3-Clause License and the GNU General
Public License v2.0; this package uses it under the **BSD 3-Clause License**,
whose text is at `implementations/swift/Sources/CZstd/LICENSE`:

> Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

## Origin

This package was extracted from **Vibe Bar**
([AstroQore/vibe-bar](https://github.com/AstroQore/vibe-bar)), where the
session adapters, the session index, and the MCP transport grew up inside the
application target. The code carries its history with it: the extraction is a
move, the license is the same AGPL-3.0-only, and the copyright holder is
unchanged.

Vibe Bar's own third-party notices cover components that did **not** come
across — its browser-cookie and Keychain utilities, its provider quota
adapters, its pricing tables, and its dependencies on
[SweetCookieKit](https://github.com/steipete/SweetCookieKit) and
[Sparkle](https://github.com/sparkle-project/Sparkle). None of those are part
of this package.

## Interoperability references

The on-disk formats this package reads are the private storage of other
projects. Reading them is reverse-engineered from observed files, not from any
published schema, and no code from these projects is included here.

- Codex CLI / Codex Desktop — `~/.codex/sessions` rollout JSONL.
- Claude Code — `~/.claude/projects` transcript JSONL.
- Claude Cowork — transcripts inside Claude.app's container.
- Gemini CLI — `~/.gemini/tmp/*/chats` session JSONL.
- AntiGravity — `~/.gemini/antigravity*/conversations` SQLite databases and
  their protobuf `gen_metadata` blobs.
- Grok Build — `~/.grok/sessions` update JSONL.
- Cursor — `~/.cursor/chats/**/store.db` SQLite stores.

All project names and trademarks belong to their respective owners. Listing a
project here does not imply affiliation, sponsorship, or endorsement, and the
formats may change without notice.
