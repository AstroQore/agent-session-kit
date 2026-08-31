import Foundation

/// The lossy encoding Claude Code uses to name a project directory, and the
/// best that can be done to undo it.
///
/// A transcript lives at `~/.claude/projects/<encoded cwd>/<session id>.jsonl`,
/// where the encoding replaces every character that cannot appear in a path
/// component with `-`. Not just `/`: a `.`, a `~`, a space, and a `_` all
/// become `-` as well, so
///
/// ```text
/// /Users/example/code/vibe-bar        →  -Users-example-code-vibe-bar
/// /Users/example/code/vibe/bar        →  -Users-example-code-vibe-bar
/// /Users/example/my code/.config      →  -Users-example-my-code--config
/// ```
///
/// all collapse together. The encoding is *not* injective, so there is no
/// decode — only a guess, and a caller must treat one as a hint.
///
/// ## Why bother at all
///
/// Because it is the only cwd available for a session with no
/// `~/.claude/sessions` entry and an empty transcript, and a board row that
/// says nothing about where a session is running is nearly useless. So:
///
/// 1. `~/.claude/sessions/<pid>.json` — exact, when a process is running.
/// 2. The first fully-stamped record's `cwd` — exact, when the file has one.
/// 3. This, as a last resort.
///
/// ``decode(directoryName:fileManager:)`` narrows the guess by asking the file
/// system which of the candidate splits actually exists, which resolves
/// `vibe-bar` correctly whenever the directory is still there. When nothing
/// matches it falls back to ``naiveDecode(directoryName:)``, which turns every
/// `-` into a `/`.
public enum ClaudeProjectPath {
    /// Encodes a working directory the way Claude Code names its project
    /// directory. Exposed so a test — and a caller building a synthetic tree —
    /// does not have to reimplement the substitution.
    public static func encode(cwd: String) -> String {
        String(cwd.map { character in
            switch character {
            case "/", ".", "~", " ", "_": "-"
            default: character
            }
        })
    }

    /// The mechanical inverse: every `-` becomes a `/`.
    ///
    /// Right for a path whose components contain no dashes and wrong for every
    /// other one, which is why it is the fallback rather than the answer.
    public static func naiveDecode(directoryName: String) -> String? {
        guard !directoryName.isEmpty else { return nil }
        let path = directoryName.replacingOccurrences(of: "-", with: "/")
        return path.hasPrefix("/") ? path : "/" + path
    }

    /// Best-effort decode, checked against the file system.
    ///
    /// Walks the dash-separated segments left to right, building one path
    /// component at a time. At each step it takes the shortest run of segments
    /// that names a directory which exists — `code` + `vibe` fails, `code` +
    /// `vibe-bar` succeeds — which is exactly the ambiguity the encoding
    /// creates, and the file system is the only thing that can settle it.
    ///
    /// Shortest match, and no backtracking. A tree where both `code/vibe` and
    /// `code/vibe-bar` exist and the session lived in the second one decodes
    /// to the first, and the walk then stops. That is a guess losing to another
    /// guess, not a bug worth a search for: the two callers that matter — a
    /// `~/.claude/sessions` entry and the transcript's own first line — are
    /// both exact, and this only runs when neither is available.
    ///
    /// Falls back to ``naiveDecode(directoryName:)`` when nothing at all
    /// resolves, and appends the unverified remainder naively when the walk
    /// stops part-way — a deleted worktree, a project on an unmounted volume.
    /// A half-verified path is more informative than a truncated one.
    ///
    /// - Parameters:
    ///   - directoryName: The project directory's name, not its path.
    ///   - fileManager: Injected so the suite can drive this against a
    ///     temporary tree rather than the machine's real one.
    public static func decode(
        directoryName: String,
        fileManager: FileManager = .default
    ) -> String? {
        let segments = directoryName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty else { return nil }

        var path = ""
        var resolvedAnything = false
        // A leading `-` (every absolute path has one) produces an empty first
        // segment; it is the root, not a component.
        var index = segments[0].isEmpty ? 1 : 0

        walk: while index < segments.count {
            var component = segments[index]
            var next = index + 1
            while true {
                if isDirectory(path + "/" + component, fileManager) {
                    path += "/" + component
                    resolvedAnything = true
                    index = next
                    continue walk
                }
                guard next < segments.count else { break walk }
                component += "-" + segments[next]
                next += 1
            }
        }

        guard resolvedAnything else { return naiveDecode(directoryName: directoryName) }
        guard index < segments.count else { return path }
        return path + "/" + segments[index...].joined(separator: "/")
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}
