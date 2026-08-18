import Foundation

/// Where Claude.app keeps Cowork ("local agent mode") transcripts, and how
/// to tell one apart from an ordinary Claude Code transcript.
///
/// Cowork writes the *same* JSONL shape Claude Code does — same `message`
/// envelope, same usage block — but inside Claude.app's own container. Its
/// transcripts are therefore listed and read like any other, and never
/// removed: the app that owns them is running.
public enum ClaudeCoworkPaths {
    /// Claude.app's own directory name for a Cowork workspace tree. Used
    /// both to find the root and to recognise a file that came from it.
    public static let directoryName = "local-agent-mode-sessions"

    public static func root(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Claude")
            .appendingPathComponent(directoryName)
    }

    /// Which harness a Claude-shaped transcript belongs to.
    ///
    /// Recognised by path *component* rather than by a prefix match against
    /// the root: `FileManager.enumerator` hands back symlink-resolved paths
    /// (`/private/var/...` for a `/var/...` root), so a prefix test silently
    /// mislabels every Cowork transcript. Claude Code's own project
    /// directories are percent-ish encoded with dashes, so a project whose
    /// cwd merely mentions this name cannot collide with a real path
    /// component.
    public static func harness(forFile file: URL) -> Harness {
        file.pathComponents.contains(directoryName) ? .claudeCowork : .claudeCode
    }

    /// Transcript files under the Cowork root.
    ///
    /// Unlike the Claude Code roots, the enumeration starts *above* a hidden
    /// `.claude` directory, so `.skipsHiddenFiles` would find nothing. Hidden
    /// entries are therefore walked, and the `/.claude/projects/` requirement
    /// is what keeps the walk to transcripts rather than to whatever else the
    /// app stores in that workspace. Symlinks are refused because they could
    /// resolve anywhere.
    public static func collectJSONL(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.path.contains("/.claude/projects/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == false { continue }
            out.append(url)
        }
        return out
    }
}
