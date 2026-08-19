import AgentSessionKit
import Foundation

/// Turns one `…/.claude/projects/<encoded cwd>` directory into the sources
/// worth tailing, for whichever harness writes Claude Code's transcript
/// format.
///
/// Claude Code and Claude Cowork write byte-identical JSONL — same records,
/// same `<session>/subagents/agent-<id>.jsonl` layout, same sidecars — so the
/// mapper, the tailer, and the seeding rules are shared rather than copied.
/// What differs between the two is where the tree is rooted, whether a
/// `~/.claude/sessions` entry can exist at all, and how liveness is decided;
/// those stay in the adapters, and this type is everything that does not.
///
/// It is a value with no state of its own: the `linker` it registers child
/// edges with belongs to the adapter that built it, so a Cowork subagent is
/// never announced to a Claude Code parent.
struct ClaudeSourceBuilder: Sendable {
    /// The harness every key this builder mints belongs to.
    let harness: Harness
    /// The parent/child join child transcripts are announced through.
    let linker: ClaudeSubagentLinker

    /// The parent transcripts directly inside `projectDirectory`, each
    /// followed by the subagents beside it.
    ///
    /// `entries` is `~/.claude/sessions` as the adapter read it, and is empty
    /// for a store that has no such directory — Cowork's transcripts live in
    /// Claude.app's container and no pid file is written for them. A
    /// transcript is worth tailing when an entry names it (a session sitting
    /// at a prompt for an hour is the most live thing on the machine and has
    /// an hour-old file) **or** when it was written to since `activeSince`.
    func sources(
        in projectDirectory: URL,
        entries: [ClaudeLiveSession],
        activeSince: Date
    ) -> [SessionSource] {
        var out: [SessionSource] = []
        for transcript in Self.transcripts(in: projectDirectory) {
            let sessionID = transcript.deletingPathExtension().lastPathComponent
            let entry = entries.isEmpty
                ? nil
                : ClaudeSessionsDirectory.session(for: sessionID, in: entries)
            let stamp = FileStamp.read(path: transcript.path)
            let isRunning = entry != nil
            let isRecent = (stamp?.modified ?? .distantPast) >= activeSince
            guard isRunning || isRecent else { continue }

            let parent = parentSource(
                transcript: transcript,
                projectDirectory: projectDirectory,
                sessionID: sessionID,
                entry: entry
            )
            out.append(parent)
            out.append(contentsOf: subagentSources(
                parent: parent,
                projectDirectory: projectDirectory,
                sessionID: sessionID,
                activeSince: isRunning ? .distantPast : activeSince
            ))
        }
        return out
    }

    private func parentSource(
        transcript: URL,
        projectDirectory: URL,
        sessionID: String,
        entry: ClaudeLiveSession?
    ) -> SessionSource {
        let key = SessionKey(harness: harness, sessionID: sessionID)
        let head = Self.headRecord(of: transcript)
        var identity = SessionIdentity(key: key, sourcePath: transcript.path)
        identity.cwd = entry?.cwd
            ?? head?.cwd
            ?? ClaudeProjectPath.decode(directoryName: projectDirectory.lastPathComponent)
        identity.gitBranch = head?.gitBranch
        identity.entrypoint = entry?.entrypoint ?? head?.entrypoint
        identity.model = head?.model
        identity.pid = entry.map { $0.pid }
        identity.procStart = entry?.procStart
        identity.title = entry?.name
        return SessionSource(key: key, primaryPath: transcript.path, seedIdentity: identity)
    }

    /// Subagent transcripts under `<project>/<session id>/subagents`.
    ///
    /// Registering the link here rather than in a tailer is deliberate: a
    /// host may discover a child and decide not to tail it, and the parent
    /// should still be told a child exists.
    private func subagentSources(
        parent: SessionSource,
        projectDirectory: URL,
        sessionID: String,
        activeSince: Date
    ) -> [SessionSource] {
        let directory = projectDirectory
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        return names.sorted().compactMap { name -> SessionSource? in
            guard name.hasPrefix(ClaudeLiveAdapter.subagentFilePrefix),
                  name.hasSuffix(".jsonl")
            else { return nil }
            let path = directory.appendingPathComponent(name).path
            guard (FileStamp.read(path: path)?.modified ?? .distantPast) >= activeSince else { return nil }

            let agentID = String(
                name.dropFirst(ClaudeLiveAdapter.subagentFilePrefix.count).dropLast(".jsonl".count)
            )
            guard !agentID.isEmpty else { return nil }
            let meta = ClaudeSubagentMeta.read(
                path: directory.appendingPathComponent(
                    "\(ClaudeLiveAdapter.subagentFilePrefix)\(agentID).meta.json"
                ).path
            )
            let key = SessionKey(
                harness: harness,
                sessionID: "\(sessionID)\(ClaudeLiveAdapter.subagentKeySeparator)"
                    + "\(ClaudeLiveAdapter.subagentFilePrefix)\(agentID)"
            )
            linker.register(
                child: key,
                parent: parent.key,
                agentType: meta?.agentType,
                toolUseID: meta?.toolUseID
            )

            var identity = SessionIdentity(key: key, sourcePath: path)
            identity.variant = ClaudeLiveAdapter.subagentVariant
            identity.parent = parent.key
            identity.parentLink = .subagent(toolUseID: meta?.toolUseID)
            identity.cwd = parent.seedIdentity.cwd
            identity.gitBranch = parent.seedIdentity.gitBranch
            identity.model = meta?.model
            identity.title = meta?.description.map { EventText.preview($0, max: 200) }
            return SessionSource(key: key, primaryPath: path, seedIdentity: identity)
        }
    }

    /// The first fully-stamped record of a transcript, from a bounded read of
    /// its head.
    ///
    /// Three lines rather than one because the head of a resumed session can
    /// open with a `queue-operation` or a `custom-title`, neither of which
    /// carries a `cwd`.
    static func headRecord(of transcript: URL) -> ClaudeTranscriptRecord? {
        for line in JSONLHeadTail.headLines(url: transcript, count: 3) {
            guard let record = ClaudeTranscriptRecord.decode(line), record.isFullyStamped else { continue }
            return record
        }
        return nil
    }

    /// The immediate subdirectories of a project root, sorted by name.
    static func subdirectories(of root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map(root.appendingPathComponent)
    }

    /// The parent transcripts in a project directory: `<session id>.jsonl`,
    /// never a subagent's file and never a dotfile.
    static func transcripts(in projectDirectory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)) ?? []
        return names.sorted()
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(ClaudeLiveAdapter.subagentFilePrefix) }
            .map(projectDirectory.appendingPathComponent)
    }
}
