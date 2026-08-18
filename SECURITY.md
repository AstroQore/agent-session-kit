# Security Policy

`agent-session-kit` reads local AI coding-agent session stores — transcripts,
project paths, and conversation databases — and serves a local MCP transport
over a Unix domain socket. Everything it touches is the user's own words and
the user's own filesystem. Treat reports and diagnostics as sensitive by
default.

## Reporting a vulnerability

Use GitHub private vulnerability reporting if it is enabled on this
repository. If it is not, open a minimal public issue describing the affected
area without including any secrets, then ask for a private channel.

Do not paste:

- API tokens, session cookies, JWTs, or Keychain values.
- Full CLI auth files or browser cookie exports.
- Real email addresses, organization IDs, account IDs, or workspace
  identifiers.
- Unsanitized session transcripts.

## What the package guarantees

- **Reads only where it is pointed.** Every discovery entry point takes an
  explicit `homeDirectory`; the adapters never widen a root, and `roots(...)`
  doubles as the containment fence `SessionDeleter` checks each removal
  target against.
- **Never follows a symlink.** Not while enumerating, not while deleting. A
  link inside a session directory could resolve anywhere.
- **Writes only to a path the caller named.** `SessionIndexStore` has no
  default location, and the MCP server creates no directory of its own — the
  host's `ensureDirectory` hook does that.
- **Re-verifies before deleting.** A `SessionDeletionPlan` carries the file to
  re-parse and the session id that must still be there; the deleter refuses on
  a mismatch, on an unreadable file, on a symlinked target, and on any path
  that resolves outside a provider root. Three of the seven providers refuse
  to plan a delete at all, because another running app owns their store.
- **No network.** The MCP socket is `AF_UNIX`, mode 0600, and nothing is ever
  bound to a network interface.
- **No secrets in logs.** `KitLog.sanitize` replaces token-shaped runs; log
  file names, never paths or transcript bodies.

## Supported versions

Pre-1.0. Security fixes target the default branch first.
