import AgentSessionKit
import Foundation

/// Reads Claude Cowork's transcripts live — the local agent runs Claude.app
/// drives itself, rather than the ones a person starts in a terminal.
///
/// ## The store
///
/// ```text
/// ~/Library/Application Support/Claude/local-agent-mode-sessions/
///   <space>/<x>/local_<uuid>/.claude/projects/<encoded cwd>/
///     <session id>.jsonl                     the session's timeline
///     <session id>/subagents/agent-<id>.jsonl  one child session each
/// ```
///
/// The transcripts are byte-for-byte the JSONL Claude Code writes, so
/// ``ClaudeRecordMapper`` and ``ClaudeSessionTailer`` are reused unchanged and
/// discovery goes through the shared ``ClaudeSourceBuilder``. Only three
/// things differ, and they are the whole of this type: the tree is rooted
/// inside another app's container and is nested several levels deeper, the
/// files are hidden behind a `.claude` directory, and there is no
/// `~/.claude/sessions` entry to ask about liveness.
///
/// The keys it mints are `SessionKey(.claudeCowork, …)`. Cowork is its own
/// harness rather than a variant of Claude Code: it is started by the app and
/// not by a person at a prompt, it has its own workspace per run, and a board
/// that folded the two together would attribute the app's background work to
/// whatever the person was doing in a terminal.
///
/// ## Read-only, permanently
///
/// Claude.app owns this tree, may hold a transcript open, and rewrites the
/// workspace when a run ends. Nothing here writes, locks, or touches a file —
/// the same stance `AgentSessionKit`'s `ClaudeCoworkSessionAdapter` takes when
/// it refuses to build a deletion plan.
///
/// ## Liveness
///
/// There is no pid file, no writer lock, and no socket. What there is, is the
/// Claude.app process that launched the run: it carries the session id in
/// `CLAUDE_CODE_SESSION_ID`, exactly as the CLI does for the processes it
/// spawns. So the probe is
///
/// - a process under `/Applications/Claude.app` whose environment names this
///   session → **alive**, with that pid;
/// - otherwise the transcript was written within ``aliveWithin`` → **alive**,
///   with no pid. The environment of another user's process cannot be read at
///   all, and a sandboxed helper's may not be either, so a fresh write is the
///   fallback rather than a contradiction;
/// - otherwise it has been quiet longer than ``deadAfter`` → **dead**;
/// - otherwise ``LivenessHint/Verdict/unknown``, which is the honest answer
///   for the minutes in between.
public struct ClaudeCoworkLiveAdapter: SourceAdapter {
    public let harness: Harness = .claudeCowork

    /// Where Claude.app is installed. A process outside this prefix is not a
    /// Cowork helper however its environment is set up — a terminal that
    /// exported `CLAUDE_CODE_SESSION_ID` by hand is not evidence of anything.
    public static let applicationPrefix = "/Applications/Claude.app/"

    /// How recently a transcript must have been written for a session with no
    /// matching helper process to still count as alive.
    ///
    /// Two minutes. Short, because this branch exists only for the case where
    /// the environment could not be read, and a long window here would keep
    /// every finished run on the board.
    public let aliveWithin: TimeInterval

    /// How quiet a transcript must be before the session behind it is called
    /// dead. Ten minutes, matching ``ClaudeLiveAdapter/deadAfter``.
    public let deadAfter: TimeInterval

    private let linker: ClaudeSubagentLinker
    private let clock: @Sendable () -> Date
    /// See ``ClaudeSourceCache``. This adapter's own, never Claude Code's.
    private let cache = ClaudeSourceCache()

    /// Creates an adapter.
    ///
    /// - Parameters:
    ///   - aliveWithin: See ``aliveWithin``.
    ///   - deadAfter: See ``deadAfter``.
    ///   - linker: The parent/child join. Its own, never Claude Code's: a
    ///     Cowork subagent belongs to a Cowork parent.
    ///   - clock: The observation clock, injected for the suite.
    public init(
        aliveWithin: TimeInterval = 120,
        deadAfter: TimeInterval = 600,
        linker: ClaudeSubagentLinker = ClaudeSubagentLinker(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.aliveWithin = aliveWithin
        self.deadAfter = deadAfter
        self.linker = linker
        self.clock = clock
    }

    /// The parent/child join this adapter announces subagents through.
    public var subagentLinker: ClaudeSubagentLinker { linker }

    // MARK: - Roots

    /// The one root, watched whole.
    ///
    /// A narrower watch is not available: the workspace directory for a run
    /// does not exist until the run starts, so there is nothing deeper to
    /// subscribe to ahead of time.
    public func watchRoots(home: String) -> [URL] {
        [ClaudeCoworkPaths.root(homeDirectory: home)]
    }

    // MARK: - Discovery

    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        try await discover(home: home, activeSince: activeSince, under: nil)
    }

    /// The same, over one `…/.claude/projects/<encoded cwd>` directory when a
    /// notification named one or something below it.
    ///
    /// Narrowing here is worth more than for Claude Code, because the sweep
    /// this replaces is a *recursive* walk of Claude.app's whole workspace
    /// tree — the depth between the root and a `.claude` directory is the
    /// app's business and cannot be assumed, so finding the project
    /// directories at all means visiting every directory under the root.
    public func discover(
        home: String,
        activeSince: Date,
        under directory: URL?
    ) async throws -> [SessionSource] {
        let projects = directory.flatMap(Self.projectDirectory(under:)).map { [$0] }
            ?? Self.projectDirectories(home: home)
        guard !projects.isEmpty else { return [] }

        let builder = ClaudeSourceBuilder(harness: harness, linker: linker, cache: cache)
        return projects.flatMap { projectDirectory in
            builder.sources(in: projectDirectory, entries: [], activeSince: activeSince)
        }
    }

    /// The `…/.claude/projects/<encoded cwd>` directory a scope sits in, or
    /// `nil` when the scope is above one — a workspace directory, or the root
    /// itself, which has to be walked to be understood.
    ///
    /// Read off the path rather than the filesystem: the segment after
    /// `/.claude/projects/` is the project directory, whatever depth the app
    /// put the whole thing at, and anything deeper — the `<session
    /// id>/subagents` directory, the `tool-results` spill below it — is news
    /// about that same project.
    static func projectDirectory(under directory: URL) -> URL? {
        let marker = "/.claude/projects/"
        let path = directory.path
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let project = rest.split(separator: "/").first else { return nil }
        return URL(fileURLWithPath: String(path[path.startIndex..<range.upperBound]) + project)
    }

    /// Every `…/.claude/projects/<encoded cwd>` directory under the Cowork
    /// root, sorted and deduplicated.
    ///
    /// Found from the transcripts rather than by walking to a fixed depth:
    /// the segments between the root and `.claude` are Claude.app's own
    /// workspace bookkeeping, and their number is not something this package
    /// should encode. `ClaudeCoworkPaths.collectJSONL` is the same sweep the
    /// on-disk index uses — hidden directories walked, symlinks refused — so
    /// a transcript can never be live here and missing there.
    ///
    /// A subagent's file sits one level further down
    /// (`<project>/<session id>/subagents/`), and its path contains
    /// `/.claude/projects/` too. The grandparent test is what keeps it out:
    /// only a parent transcript has `projects` two components above it, and
    /// the builder picks the children up from the parent anyway.
    static func projectDirectories(home: String) -> [URL] {
        let root = ClaudeCoworkPaths.root(homeDirectory: home)
        var seen: Set<String> = []
        var out: [URL] = []
        for file in ClaudeCoworkPaths.collectJSONL(under: root).sorted(by: { $0.path < $1.path }) {
            let directory = file.deletingLastPathComponent()
            guard directory.deletingLastPathComponent().lastPathComponent == "projects" else { continue }
            guard seen.insert(directory.path).inserted else { continue }
            out.append(directory)
        }
        return out
    }

    // MARK: - Tailing

    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        ClaudeSessionTailer(source: source, cursor: cursor, linker: linker, clock: clock)
    }

    // MARK: - Liveness

    /// Any `.jsonl` below a `.claude/projects` directory.
    ///
    /// Deliberately looser than ``ClaudeLiveAdapter/mightBeSessionFile(path:)``:
    /// the workspace layout above `.claude` is Claude.app's, it changes
    /// between releases, and the cost of being wrong is one extra
    /// rediscovery. Everything else the app writes into a workspace —
    /// settings, caches, the `tool-results` spill — is excluded by the
    /// extension or by not being under `projects` at all.
    public func mightBeSessionFile(path: String) -> Bool {
        path.hasSuffix(".jsonl") && path.contains("/.claude/projects/")
    }

    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        // A subagent has no process of its own; it runs inside the session it
        // was spawned from and is exactly as alive as that one.
        let sessionID = ClaudeLiveAdapter.rootSessionID(of: identity.key)

        for process in table.find(where: { $0.executablePath.hasPrefix(Self.applicationPrefix) }) {
            guard let environment = table.environment(pid: process.pid) else { continue }
            guard environment[SessionEnvironmentVariables.claudeSessionID] == sessionID else { continue }
            return LivenessHint(
                verdict: .alive,
                pid: process.pid,
                evidence: "Claude.app helper pid \(process.pid) carries "
                    + "\(SessionEnvironmentVariables.claudeSessionID) for this session"
            )
        }

        guard let age = LockFileProbe.ageOfLastWrite(path: identity.sourcePath) else {
            return .unknown("no Claude.app helper names this session, and the transcript could not be stat'd")
        }
        if age <= aliveWithin {
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "no Claude.app helper names this session; transcript written \(Int(age))s ago"
            )
        }
        if age > deadAfter {
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "no Claude.app helper names this session; "
                    + "transcript quiet for \(Int(age / 60)) min"
            )
        }
        return .unknown(
            "no Claude.app helper names this session; transcript written \(Int(age))s ago"
        )
    }
}
