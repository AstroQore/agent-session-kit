# Releasing

How a version of this package gets cut, and why each step is there. If you
only remember one thing: **a published tag never moves.**

## Versioning

Bare semver tags — `0.1.0`, `0.2.0`, `0.3.0`. No `v` prefix; the tag string
*is* the version string, which is what lets `AgentSessionKitInfo.version`
and a `SwiftPM` pin be compared as plain text.

While the package is `0.x` the major number is parked at zero and the other
two carry the meaning:

| Bump | When |
| ---- | ---- |
| **minor** (`0.2.0` → `0.3.0`) | Anything a consumer could trip over: a removed or renamed API, a changed signature, a changed default, a new adapter or provider case, a bumped `eventSchemaVersion`, a new storage key. Under `0.x` semver puts breaking changes here, so this is also the ordinary "new feature" bump. |
| **patch** (`0.3.0` → `0.3.1`) | Fixes and internals only. A parser that stops mis-reading a field, a narrowed discovery scope, docs, tests, CI. Nothing a caller has to react to. |

`SessionProvider.rawValue`, `Harness.rawValue`, and the SQLite schema are
storage keys: they land in host caches. Changing one is a minor bump *and*
needs a note in the changelog saying what a host has to re-seed.

Nothing here is `1.0` yet, so `exact:` is the pin a host should use. See
"What consumers do".

## The version constant

`Sources/AgentSessionKit/AgentSessionKitInfo.swift` holds
`AgentSessionKitInfo.version`. This package is linked *statically* by its
hosts: once it is compiled in there is no bundle, no `Info.plist`, and no
dylib for anyone to read a version off. The constant is the only answer to
"which agent-session-kit is inside this binary?".

`AgentSessionKitInfoTests` pins that constant to the newest `## [X.Y.Z]`
section of `CHANGELOG.md`. So the two move together, in one commit, or
`swift test` fails — on the pull request, long before a tag exists.

## Cutting a release

1. **Start from a green `main`.** `swift build && swift test` locally, and
   the CI run for the merge commit is green. A release is not the place to
   discover a failure.
2. **Move `[Unreleased]` down.** In `CHANGELOG.md`, rename the
   `## [Unreleased]` heading to `## [X.Y.Z] - YYYY-MM-DD`, add a one- or
   two-sentence summary under it, and put a fresh empty `## [Unreleased]`
   above. The section body becomes the published release notes verbatim, so
   write it for a reader who is deciding whether to bump their pin.
3. **Bump the constant.** Set `AgentSessionKitInfo.version` to `X.Y.Z`.
4. **Commit.** `chore: release X.Y.Z`, on a branch, through a pull request
   like any other change. The suite runs there and will reject a constant
   that does not match the changelog. (Steps 2–4 can also ride along at the
   end of the feature pull request that earned the version, which is how
   0.3.0 was cut — the point is only that they land together.)
5. **Tag the merged commit.**

   ```sh
   git checkout main && git pull --ff-only
   git tag -a X.Y.Z -m "agent-session-kit X.Y.Z"
   git push origin X.Y.Z
   ```

   Annotated, on `main`, named exactly as the changelog section.
6. **Let the workflow publish.** `.github/workflows/release.yml` fires on
   the tag: it re-checks that `AgentSessionKitInfo.version` and a
   `## [X.Y.Z]` changelog section both agree with the tag, builds, tests,
   extracts that changelog section into the release notes, and creates a
   **published** (never draft, never prerelease) GitHub Release. Every check
   is a refusal, not a repair — the workflow would rather publish nothing
   than publish something that does not match its own source.
7. **Confirm.**

   ```sh
   gh release view X.Y.Z -R AstroQore/agent-session-kit
   ```

## If the workflow fails

Fix forward. Do not delete and re-push the tag.

- **A check failed and nothing was published.** The tag is wrong, not the
  release. Land the correction on `main` and cut the *next* patch version
  (`X.Y.Z+1`) from it. The bad tag stays where it is, releaseless.
- **The build or tests failed.** Same answer: `main` gets the fix, the next
  version gets the tag.
- **Only the publish step failed** (a token blip, a transient API error) —
  re-run the failed job. The source is fine; the tag already points at the
  right commit.

A tag that has been fetched by anybody — CI, a consumer's
`Package.resolved`, another checkout — is permanent. Moving it makes two
different source trees answer to the same version, which is the one failure
mode a pinned dependency is supposed to make impossible.

## What consumers do

A release does **not** reach anyone's users on its own. This package is
compiled into a host application; a new tag reaches a person only when the
host bumps its pin and ships a new build of itself.

[Vibe Bar](https://github.com/AstroQore/vibe-bar) pins it exactly:

```swift
.package(url: "https://github.com/AstroQore/agent-session-kit.git", exact: "0.3.0")
```

`exact:` on purpose — Vibe Bar's release builds resolve from a clean
checkout with no committed `Package.resolved`, so the pin is the only thing
that makes two builds of the same commit contain the same package. Bumping
it is a deliberate, reviewable edit: Vibe Bar has a scheduled
`bump-agent-session-kit` workflow that opens the pull request when a newer
tag appears, and its Settings › System pane shows the version actually
compiled into the running app — labelled so that a newer kit reads as
"ships with the next Vibe Bar build", not as something the app can fetch.

So: cut the tag when the API is ready to be depended on, not when the host
happens to need it. The host decides when its users see it.
