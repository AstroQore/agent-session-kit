import Foundation

/// The encoding Grok Build uses to name the directory a session's files live
/// under, and its exact inverse.
///
/// A session lives at
/// `~/.grok/sessions/<encoded cwd>/<session id>/`, where the encoding is
/// ordinary RFC 3986 percent-encoding of the working directory:
///
/// ```text
/// /Users/example/code/demo      →  %2FUsers%2Fexample%2Fcode%2Fdemo
/// /Users/example/my code        →  %2FUsers%2Fexample%2Fmy%20code
/// /Users/example/.config        →  %2FUsers%2Fexample%2F.config
/// ```
///
/// Unlike Claude Code's project-directory naming — see ``ClaudeProjectPath``,
/// which collapses `/`, `.`, `~`, ` `, and `_` all onto `-` and is therefore
/// not invertible — this one is lossless. `%2F` is a separator and a literal
/// `/` cannot appear in a path component in the first place, so
/// ``decodeCwd(directoryName:)`` returns the working directory the harness was
/// launched in, not a guess at it. That is why the adapter prefers it over the
/// `info.cwd` in `summary.json`: the directory name is always there, even for a
/// session whose summary was never written or cannot be parsed.
public enum GrokSessionsPath {
    /// The characters Grok leaves unescaped: RFC 3986's unreserved set.
    ///
    /// Matched against the real store rather than assumed — `-`, `.`, `_`, and
    /// `~` all appear literally in directory names there, and everything else
    /// outside `[A-Za-z0-9]` appears escaped.
    static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Encodes a working directory the way Grok Build names its session
    /// directory.
    ///
    /// Exposed so a test — and a caller building a synthetic tree — does not
    /// have to reimplement the escaping. Returns `nil` only for input Foundation
    /// refuses to encode, which no path produces.
    public static func encode(cwd: String) -> String? {
        cwd.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// The working directory a session directory's name stands for.
    ///
    /// Returns `nil` for an empty name and for one whose percent-escapes are
    /// malformed — a directory somebody else created under
    /// `~/.grok/sessions`, which is not a session and should not be given an
    /// invented cwd.
    public static func decodeCwd(directoryName: String) -> String? {
        guard !directoryName.isEmpty,
              let decoded = directoryName.removingPercentEncoding,
              !decoded.isEmpty
        else { return nil }
        return decoded
    }
}
