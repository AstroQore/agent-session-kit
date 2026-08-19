# Contributing

Thanks for taking a look. This package is small on purpose; the bar for
adding to it is that the code is provider-agnostic, testable without a
network, and safe to run against a real developer's home directory.

## Getting set up

```sh
swift build
swift test
```

macOS 26, Swift 6.2 or newer. No package dependencies, so there is nothing to
resolve or vendor.

`AgentSessionKit` is still on the Swift 5 language mode while the adapters are
migrated. `AgentSessionLive` is Swift 6 from the start — new concurrency-aware
code belongs there or arrives with its own migration.

## What a change has to hold

- **No personal paths or ids.** No `/Users/<name>`, no real org UUIDs, no real
  tokens or cookies, in source, tests, or fixtures. Use `/Users/example/...`
  and synthetic identifiers. This repository is AGPL and every diff is
  public.
- **Never write outside a caller-provided directory.** Paths are parameters,
  not constants. If new code needs somewhere to put a file, it takes a `URL`.
- **Never follow a symlink** while enumerating or deleting. A link inside a
  session store can resolve anywhere.
- **Parsing is O(n) and bounded.** Use `JSONLLineScanner.forEachLine` for a
  whole-file walk and `JSONLHeadTail` for metadata. A moving cursor, never
  `removeSubrange` in a loop, and never `String(contentsOf:)` on a
  transcript.
- **Parsing is total.** A corrupt line yields `nil` or an empty string; it
  never throws. One bad rollout must not sink the session list.
- **Leave a field `nil` rather than inventing it.** If a log does not record
  the model, the answer is "unknown" — not the vendor's usual model.
- **Log through `KitLog`.** File names only; never paths, transcript text, or
  anything token-shaped.

## Adding a harness

1. A `SessionProvider` case, its `displayName` (from `HarnessCatalog`), its
   `defaultHarness`, and an honest `supportsDeletion` — `false` if another
   running process owns the store.
2. A `SessionProviderAdapter`. `roots(homeDirectory:)` is both the discovery
   scope and the containment fence the deleter checks against, so keep it as
   narrow as the store actually is.
3. Register it in `SessionProviderRegistry.standard`.
4. Tests that build a synthetic tree under a temp directory and assert on
   metadata, transcript, and deletion planning. No fixture may name a real
   user.
5. A row in the README table, including what the format genuinely cannot
   answer.

## Tests

Every adapter test writes its own fixture tree into `NSTemporaryDirectory()`
and tears it down. Nothing reads the real `~`. A test that polls is a test
that flakes — the socket tests block with a receive timeout instead.

## Commits and pull requests

Conventional-commit subjects (`feat:`, `fix:`, `refactor:`, `test:`,
`docs:`, `chore:`). Branches use the same prefixes (`feat/`, `fix/`, …).
Describe what changed and how you verified it; `swift test` output is enough
for most changes.

Use your own git identity. If you would rather not publish a personal
mailbox, configure GitHub's privacy address for this repository:

```sh
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

`Co-Authored-By:` trailers are welcome when more than one person or agent
shaped a commit.

Add what you changed to `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), and
leave `AgentSessionKitInfo.version` alone — the version constant and a dated
changelog section move together, in the release commit. See
[RELEASING.md](RELEASING.md) for how a version is cut.

## Security

Please do not open a public issue for a vulnerability. See
[SECURITY.md](SECURITY.md).
