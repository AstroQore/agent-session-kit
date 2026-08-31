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

    /// Cowork deliberately runs Claude Code inside an isolated `outputs`
    /// directory, so the JSONL `cwd` is not the folder the user asked it to
    /// work on. Structured tool inputs retain the original absolute file
    /// paths, however. A bounded head window is enough to recover their
    /// common directory without scanning a large completed transcript.
    public static func inferredProjectDirectory(fileURL: URL) -> String? {
        let workspace = workspaceRoot(containing: fileURL)
        let lines = JSONLHeadTail.headLines(url: fileURL, count: 40).compactMap(SessionParsing.json)
        var paths: [URL] = []
        for line in lines {
            collectStructuredPaths(in: line, into: &paths)
        }
        let directories = paths.compactMap { candidate -> URL? in
            guard candidate.path.hasPrefix("/") else { return nil }
            if let workspace, isInside(candidate, root: workspace) { return nil }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent()
            }
            return candidate.pathExtension.isEmpty ? candidate : candidate.deletingLastPathComponent()
        }
        return commonDirectory(directories)?.path
    }

    private static let structuredPathKeys: Set<String> = [
        "file_path", "filepath", "filename", "originalfile"
    ]

    private static func collectStructuredPaths(in value: Any, into paths: inout [URL]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if structuredPathKeys.contains(key.lowercased()),
                   let raw = SessionParsing.string(child), raw.hasPrefix("/") {
                    paths.append(URL(fileURLWithPath: raw).standardizedFileURL)
                }
                collectStructuredPaths(in: child, into: &paths)
            }
        } else if let array = value as? [Any] {
            for child in array { collectStructuredPaths(in: child, into: &paths) }
        }
    }

    private static func workspaceRoot(containing fileURL: URL) -> URL? {
        var cursor = fileURL.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.lastPathComponent.hasPrefix("local_") { return cursor }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let path = candidate.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "/" + prefix || path.hasPrefix("/" + prefix + "/")
    }

    private static func commonDirectory(_ directories: [URL]) -> URL? {
        guard var common = directories.first?.standardizedFileURL.pathComponents else { return nil }
        for directory in directories.dropFirst() {
            let components = directory.standardizedFileURL.pathComponents
            let count = zip(common, components).prefix { $0 == $1 }.count
            common = Array(common.prefix(count))
            if common.count <= 3 { return nil } // Never label the user's home as a project.
        }
        guard common.count > 3 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }
}
