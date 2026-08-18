import Foundation

/// Where Cursor keeps the four things a live view of an agent needs, and the
/// lossy slug that joins two of them.
///
/// ```text
/// ~/.cursor/chats/<workspace hash>/<agent id>/
///     store.db                    the conversation, content-addressed
///     meta.json                   {schemaVersion, createdAtMs, updatedAtMs, hasConversation, cwd}
/// ~/.cursor/projects/<cwd slug>/
///     agent-transcripts/<agent id>/<agent id>.jsonl    the thin transcript
///     worker.sock                 the CLI worker's socket; may be stale
/// ~/.cursor/agent-cli-state.json  {workerIdsByDisplayName}
/// ~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/
///     cursor-agent-worker-<worker id>.pid    the running `cursor-agent` pid
///     cursor-agent-worker-<worker id>.log
/// ```
///
/// The store is keyed by a *workspace hash* and the transcript by a *cwd
/// slug*, and neither can be derived from the other — the hash is opaque. The
/// join therefore goes through the cwd, which `meta.json` records verbatim:
/// slug the cwd, and the transcript directory is found. ``cwd(forSlug:)``
/// exists for the other direction and is a guess, not an inverse.
public enum CursorPaths {
    /// One SQLite store per conversation lives under here, two levels deep.
    public static let chatsPath = ".cursor/chats"
    /// Thin transcripts and worker sockets, one directory per project.
    public static let projectsPath = ".cursor/projects"
    /// The VS Code extension's global storage, where the worker pid files are.
    public static let workerPath =
        "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker"

    /// The store file's name inside an agent's directory.
    public static let storeFileName = "store.db"
    /// The metadata sidecar's name inside an agent's directory.
    public static let metaFileName = "meta.json"
    /// The directory under a project that holds one directory per agent.
    public static let transcriptsDirectoryName = "agent-transcripts"
    /// The CLI worker's socket, one per project.
    public static let workerSocketName = "worker.sock"
    /// Every worker pid file starts with this.
    public static let workerFilePrefix = "cursor-agent-worker-"

    // MARK: - Roots

    /// `~/.cursor/chats`.
    public static func chatsRoot(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(chatsPath)
    }

    /// `~/.cursor/projects`.
    public static func projectsRoot(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(projectsPath)
    }

    /// The `anysphere.cursor-agent-worker` global-storage directory.
    public static func workerRoot(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(workerPath)
    }

    // MARK: - One agent

    /// `~/.cursor/chats/<workspace hash>/<agent id>/store.db`.
    public static func storePath(home: String, workspaceHash: String, agentID: String) -> String {
        agentDirectory(home: home, workspaceHash: workspaceHash, agentID: agentID)
            .appendingPathComponent(storeFileName).path
    }

    /// `~/.cursor/chats/<workspace hash>/<agent id>/meta.json`.
    public static func metaPath(home: String, workspaceHash: String, agentID: String) -> String {
        agentDirectory(home: home, workspaceHash: workspaceHash, agentID: agentID)
            .appendingPathComponent(metaFileName).path
    }

    /// `~/.cursor/chats/<workspace hash>/<agent id>`.
    public static func agentDirectory(home: String, workspaceHash: String, agentID: String) -> URL {
        chatsRoot(home: home)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
    }

    /// The `meta.json` beside a `store.db`.
    public static func metaPath(forStore store: String) -> String {
        URL(fileURLWithPath: store)
            .deletingLastPathComponent()
            .appendingPathComponent(metaFileName)
            .path
    }

    // MARK: - The thin transcript

    /// `~/.cursor/projects/<slug>/agent-transcripts/<agent id>/<agent id>.jsonl`.
    ///
    /// Only a path — the file exists exactly when a `cursor-agent` CLI drove
    /// the session, and not at all for an agent started inside the IDE.
    public static func thinTranscriptPath(home: String, slug: String, agentID: String) -> String {
        projectsRoot(home: home)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(transcriptsDirectoryName, isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("\(agentID).jsonl")
            .path
    }

    /// The thin transcript for an agent, when one is on disk.
    ///
    /// Tries the slug of `cwd` first, which is one `stat`. Falls back to a
    /// scan of every project directory, because a session whose cwd moved —
    /// or whose `meta.json` could not be read — still has exactly one
    /// transcript directory named after its agent id. The scan is one
    /// `readdir` of `~/.cursor/projects` plus one `stat` per project, which is
    /// tens of syscalls on a machine with a lot of projects and zero on a
    /// machine where the first guess hit.
    public static func findThinTranscript(
        home: String,
        agentID: String,
        cwd: String?,
        fileManager: FileManager = .default
    ) -> String? {
        if let cwd, !cwd.isEmpty {
            let candidate = thinTranscriptPath(home: home, slug: slug(forCWD: cwd), agentID: agentID)
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: projectsRoot(home: home).path)) ?? []
        for slug in names.sorted() {
            let candidate = thinTranscriptPath(home: home, slug: slug, agentID: agentID)
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Slugs

    /// `/Users/example/proj` → `Users-example-proj`.
    ///
    /// Only `/` is substituted, and the leading one is dropped rather than
    /// turned into an empty first segment. A trailing slash is dropped too, so
    /// that a cwd a shell expanded with one slugs the same as one without.
    public static func slug(forCWD cwd: String) -> String {
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/") { path.removeFirst() }
        return path.replacingOccurrences(of: "/", with: "-")
    }

    /// A guess at the cwd behind a slug.
    ///
    /// Lossy in one direction only: `/` became `-`, so a path component that
    /// contained a dash is indistinguishable from a directory boundary
    /// (`private-tmp-vibe-bar` is both `/private/tmp/vibe/bar` and
    /// `/private/tmp/vibe-bar`). The file system settles it where it can — the
    /// same shortest-match walk ``ClaudeProjectPath/decode(directoryName:fileManager:)``
    /// does — and the naive all-dashes-are-slashes reading is the fallback.
    ///
    /// This is a last resort. `meta.json` records the cwd exactly, and an
    /// adapter should prefer it every time.
    public static func cwd(forSlug slug: String, fileManager: FileManager = .default) -> String? {
        guard !slug.isEmpty else { return nil }
        let segments = slug.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var path = ""
        var resolvedAnything = false
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

        guard resolvedAnything else { return "/" + slug.replacingOccurrences(of: "-", with: "/") }
        guard index < segments.count else { return path }
        return path + "/" + segments[index...].joined(separator: "/")
    }

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    // MARK: - Worker files

    /// `~/.cursor/projects/<slug>/worker.sock`.
    public static func workerSocketPath(home: String, slug: String) -> String {
        projectsRoot(home: home)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(workerSocketName)
            .path
    }

    /// Every `cursor-agent-worker-<id>.pid` currently on disk.
    ///
    /// The `.log` sibling is deliberately not returned: it carries a running
    /// agent's own output, which is transcript content this package does not
    /// read for any reason.
    public static func workerPIDFiles(home: String, fileManager: FileManager = .default) -> [URL] {
        let root = workerRoot(home: home)
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted()
            .filter { $0.hasPrefix(workerFilePrefix) && $0.hasSuffix(".pid") }
            .map(root.appendingPathComponent)
    }

    /// The pid inside a worker pid file, or `nil` when the file is not there
    /// or does not hold a plausible one.
    ///
    /// Bounded: a pid is at most a handful of digits, and this reads at most
    /// 64 bytes so that a file something else wrote cannot be pulled into
    /// memory whole.
    public static func workerPID(atPath path: String) -> pid_t? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(text), value > 0 else { return nil }
        return pid_t(value)
    }
}
