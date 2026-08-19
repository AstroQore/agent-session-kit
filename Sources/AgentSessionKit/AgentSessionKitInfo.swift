import Foundation

/// What this build of the package *is* — the one place its own version
/// number is written down.
///
/// A host links this package statically. Once it is compiled in, there is
/// nothing on disk left to interrogate: no bundle, no `Info.plist`, no
/// dylib to read a version off. So the version travels as a constant, and
/// `AgentSessionKitInfoTests` pins that constant to the top released
/// section of `CHANGELOG.md` — bumping one without the other fails the
/// suite before it can fail a release.
///
/// The corollary matters to anyone showing this in a UI: the number below
/// is the version *compiled into the host binary the user is running*, not
/// the newest tag on GitHub. A newer release of this package reaches a user
/// only when the host bumps its pin and ships a new build of itself.
public enum AgentSessionKitInfo {
    /// The version this source tree will be (or was) released as.
    ///
    /// Semver, bare — no `v` prefix, matching the tags. Bumping it is part
    /// of the release commit; see `RELEASING.md`.
    public static let version = "0.4.0"

    /// Where the package lives. Public because a host that shows the
    /// version usually wants somewhere to send the reader.
    public static let repositoryURL = URL(string: "https://github.com/AstroQore/agent-session-kit")!

    /// The GitHub Release page for a given version.
    ///
    /// Tags are bare `X.Y.Z`, so the tag *is* the version string; a leading
    /// `v` is tolerated on input and stripped, because a caller reading a
    /// tag out of an API response should not have to know that.
    public static func releaseNotesURL(for version: String) -> URL {
        let tag = normalizedTag(version)
        guard !tag.isEmpty,
              let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://github.com/AstroQore/agent-session-kit/releases/tag/\(escaped)")
        else {
            return releasesURL
        }
        return url
    }

    /// The release page for the version compiled into this binary.
    public static var bundledReleaseNotesURL: URL { releaseNotesURL(for: version) }

    /// All releases, for when a specific tag cannot be named.
    public static let releasesURL = URL(string: "https://github.com/AstroQore/agent-session-kit/releases")!

    /// Trim whitespace and an optional `v`/`V` prefix. Kept here rather
    /// than in the host so every consumer strips it the same way.
    public static func normalizedTag(_ raw: String) -> String {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.count > 1, tag.hasPrefix("v") || tag.hasPrefix("V") {
            let rest = tag.dropFirst()
            if rest.first?.isNumber == true { tag = String(rest) }
        }
        return tag
    }
}
