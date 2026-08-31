import AgentSessionKit
import Foundation

/// The live view of Cursor: one SQLite store per agent, watched through its
/// WAL, joined to the thin transcript a `cursor-agent` CLI writes beside it.
///
/// ## The store
///
/// ```text
/// ~/.cursor/chats/<workspace hash>/<agent id>/
///     store.db      the conversation: content-addressed blobs, hex-JSON card
///     meta.json     {schemaVersion, createdAtMs, updatedAtMs, hasConversation, cwd}
/// ~/.cursor/projects/<cwd slug>/
///     agent-transcripts/<agent id>/<agent id>.jsonl   turn boundaries, CLI only
///     worker.sock                                     the CLI worker; may be stale
/// ~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/
///     cursor-agent-worker-<worker id>.pid             the running agent's pid
/// ```
///
/// ``CursorStoreReader`` owns the graph, ``CursorMessageMapper`` and
/// ``CursorThinTranscriptMapper`` own the translation, and
/// ``CursorSessionTailer`` composes the two sources. This type owns everything
/// around them: which stores are worth tailing, what can be known about one
/// before its graph is walked, and whether a `cursor-agent` is still there.
///
/// ## The `.db` is the primary path
///
/// A source's ``SessionSource/primaryPath`` is the `store.db`, which is what
/// makes ``IngestCoordinator`` register the `-wal` and `-shm` siblings and
/// keep its safety-net poll running. That matters more here than for a JSONL
/// harness: Cursor holds the database open in WAL mode, so a whole turn can
/// land in `-wal` and only reach the `.db` at a checkpoint minutes later —
/// and a WAL write is often a store into an already-sized `-shm` that
/// FSEvents does not report at all.
///
/// ## Discovery
///
/// A store is worth tailing when `meta.json`'s `updatedAtMs` or the database's
/// own mtime is at or after the cutoff. `meta.json` is checked first because
/// reading it does not open somebody else's live database.
///
/// A running `cursor-agent` overrides the cutoff, the way a held writer lock
/// does for Codex: when any worker pid file names a live process *and* the
/// project a store belongs to has a `worker.sock`, the store is discovered
/// however old it is. That over-includes — every agent of a project with a
/// live worker, not just the one the worker is driving — because the pid file
/// does not name an agent and only ``probeLiveness(_:table:home:)``, which has
/// a process table to ask, can narrow it. Over-including costs an idle row;
/// under-including loses the live one.
///
/// ## Liveness
///
/// In order of how much each signal can be trusted:
///
/// 1. A worker pid that is **running** and whose environment names this agent
///    in `CURSOR_AGENT_CHAT_ID`, or whose working directory is the session's →
///    **alive**, with the pid.
/// 2. The store's WAL **written within ``aliveWithin``** → alive. Somebody is
///    writing this conversation right now, whoever it is.
/// 3. A `worker.sock` that **accepts a connection** → unknown. A worker is up,
///    but it serves a whole project and this agent may be idle inside it.
/// 4. Quiet for longer than ``deadAfter`` → **dead**.
/// 5. Anything else → unknown.
///
/// The command line is never read. `cursor-agent` is invoked with
/// `--api-key crsr_…`, so its argv carries a live credential; ``ProcessTable``
/// sanitizes it, and this adapter does not touch it even so.
public struct CursorLiveAdapter: SourceAdapter {
    public let harness: Harness = .cursor

    /// How recently the store must have been written for the write alone to
    /// count as life.
    ///
    /// Thirty seconds. Cursor rewrites the store on every step of a turn, so a
    /// working agent touches it far more often than this; a longer window
    /// would keep calling a finished session alive, and a shorter one would
    /// blink during a slow model call.
    public let aliveWithin: TimeInterval

    /// How long a store must go untouched, with no worker evidence at all,
    /// before the session behind it is called dead.
    ///
    /// Ten minutes, matching the other adapters. A lingering row is the
    /// cheaper mistake than a row that vanishes while somebody reads it.
    public let deadAfter: TimeInterval

    /// The environment variable `cursor-agent` passes its agent id down in.
    /// Spelled once in ``SessionEnvironmentVariables``, which is also where
    /// the cross-harness linker reads it from.
    public static let chatIDVariable = SessionEnvironmentVariables.cursorChatID

    /// ``SessionIdentity/entrypoint`` for a session a CLI drove — the ones
    /// with a thin transcript.
    public static let cliEntrypoint = "cursor-agent"
    /// ``SessionIdentity/entrypoint`` for a session started inside the IDE.
    public static let ideEntrypoint = "cursor-ide"

    private let clock: @Sendable () -> Date

    /// The conversation card, keyed by the store it was read out of. See
    /// ``source(home:store:stamp:agentID:meta:)``.
    private let cardCache = DiscoveryCache<FileStamp, CursorStoreMeta?>()
    /// `meta.json`, keyed by its own stamp.
    private let agentMetaCache = DiscoveryCache<FileStamp, CursorAgentMeta?>()

    /// Creates an adapter.
    ///
    /// - Parameters:
    ///   - aliveWithin: See ``aliveWithin``.
    ///   - deadAfter: See ``deadAfter``.
    ///   - clock: The observation clock, injected so the suite does not have
    ///     to wait for real time to pass.
    public init(
        aliveWithin: TimeInterval = 30,
        deadAfter: TimeInterval = 600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.aliveWithin = aliveWithin
        self.deadAfter = deadAfter
        self.clock = clock
    }

    // MARK: - Watching

    /// The chats tree, the projects tree, and the worker directory.
    ///
    /// The worker directory is watched even though nothing is tailed from it:
    /// a pid file appearing there is a `cursor-agent` starting, and on a
    /// session Cursor has not written to yet it is the only notification that
    /// anything happened.
    public func watchRoots(home: String) -> [URL] {
        [
            CursorPaths.chatsRoot(home: home),
            CursorPaths.projectsRoot(home: home),
            CursorPaths.workerRoot(home: home)
        ]
    }

    // MARK: - Discovery

    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        try await discover(home: home, activeSince: activeSince, under: nil)
    }

    /// The same, over one workspace or one agent directory when a
    /// notification named one.
    ///
    /// The tree is `chats/<workspace hash>/<agent id>/`, and everything a
    /// turn writes — the store, its `-wal` and `-shm`, `meta.json` — is in
    /// the agent's own directory. A change under `projects/` or in the worker
    /// directory is a `cursor-agent` starting or a socket appearing, which
    /// can make a store far older than the cutoff worth tailing, so those
    /// sweep.
    public func discover(
        home: String,
        activeSince: Date,
        under directory: URL?
    ) async throws -> [SessionSource] {
        let agents = agentDirectories(home: home, under: directory)
        guard !agents.isEmpty else { return [] }

        let hasLiveWorker = Self.hasLiveWorker(home: home)
        var sources: [SessionSource] = []
        for agent in agents {
            let store = agent.appendingPathComponent(CursorPaths.storeFileName)
            guard let stamp = FileStamp.read(path: store.path) else { continue }
            let metaPath = CursorPaths.metaPath(forStore: store.path)
            let meta = agentMetaCache.value(path: metaPath, version: .version(ofPath: metaPath)) {
                DiscoveryIO.countFileRead()
                return CursorAgentMeta.read(path: metaPath)
            }

            let written = Self.lastWrite(store: store.path, stamp: stamp, meta: meta)
            var include = written >= activeSince
            if !include, hasLiveWorker, let cwd = meta?.cwd {
                include = FileManager.default.fileExists(
                    atPath: CursorPaths.workerSocketPath(
                        home: home, slug: CursorPaths.slug(forCWD: cwd)
                    )
                )
            }
            guard include else { continue }
            guard let source = source(
                home: home,
                store: store,
                stamp: stamp,
                agentID: agent.lastPathComponent,
                meta: meta
            ) else { continue }
            sources.append(source)
        }
        return sources.sorted { $0.key.sessionID < $1.key.sessionID }
    }

    /// The agent directories a scope names.
    ///
    /// A scope at or above `chats/` is every agent of every workspace; a
    /// workspace directory is its own agents; an agent directory, or anything
    /// below one, is that agent. A scope elsewhere under the declared roots —
    /// the projects tree, the worker directory — is not narrowable, and
    /// sweeps rather than answering nothing.
    func agentDirectories(home: String, under directory: URL?) -> [URL] {
        let root = CursorPaths.chatsRoot(home: home)
        func everyAgent() -> [URL] {
            subdirectories(of: root).flatMap(subdirectories)
        }
        guard let directory else { return everyAgent() }

        let path = directory.path
        if DiscoveryIO.path(root.path, isUnder: path) { return everyAgent() }
        guard DiscoveryIO.path(path, isUnder: root.path) else { return everyAgent() }

        let relative = path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        guard let workspace = relative.first else { return everyAgent() }
        let workspaceDirectory = root.appendingPathComponent(workspace)
        guard relative.count >= 2 else { return subdirectories(of: workspaceDirectory) }
        return [workspaceDirectory.appendingPathComponent(relative[1])]
    }

    /// Builds a source, reading the conversation card for the title and mode.
    ///
    /// Returns `nil` when the card names an agent other than the directory it
    /// sits in. The directory name is the key everything else is derived from
    /// — the transcript path, the cursor, the environment match — so a
    /// disagreement means this is not the store it claims to be, and guessing
    /// which half to trust would key a session on the wrong agent rather than
    /// skip a file. A card that cannot be read *at all* is not a
    /// disagreement: the store is Cursor's and may be busy, and a row with no
    /// title beats no row.
    private func source(
        home: String,
        store: URL,
        stamp: FileStamp,
        agentID: String,
        meta: CursorAgentMeta?
    ) -> SessionSource? {
        guard !agentID.isEmpty else { return nil }
        // The card is one SQLite open of a database Cursor holds, which is
        // the most expensive thing in this adapter's discovery. It is keyed
        // on the store's own stamp rather than on the WAL's: the title and
        // the mode reach the `.db` on a checkpoint, and re-opening the store
        // on every WAL write of a busy conversation would cost far more than
        // learning a renamed title a checkpoint late is worth.
        let card = cardCache.value(path: store.path, version: stamp) {
            DiscoveryIO.countFileRead()
            return CursorStoreReader(path: store.path).readMeta()
        }
        if let card, card.agentID.caseInsensitiveCompare(agentID) != .orderedSame { return nil }

        let cwd = meta?.cwd
        let transcript = CursorPaths.findThinTranscript(home: home, agentID: agentID, cwd: cwd)

        let key = SessionKey(harness: harness, sessionID: agentID)
        var identity = SessionIdentity(key: key, sourcePath: store.path)
        identity.cwd = cwd
        identity.title = card?.displayTitle
        identity.variant = card?.mode
        identity.entrypoint = transcript == nil ? Self.ideEntrypoint : Self.cliEntrypoint

        return SessionSource(
            key: key,
            primaryPath: store.path,
            auxiliaryPaths: transcript.map { [$0] } ?? [],
            seedIdentity: identity
        )
    }

    /// The most recent evidence that anything wrote this agent: `meta.json`'s
    /// own stamp, the database's mtime, and the WAL's.
    static func lastWrite(store: String, stamp: FileStamp, meta: CursorAgentMeta?) -> Date {
        var latest = stamp.modified
        if let updated = meta?.updatedAt, updated > latest { latest = updated }
        if let wal = FileStamp.read(path: store + "-wal")?.modified, wal > latest { latest = wal }
        return latest
    }

    /// Whether any `cursor-agent-worker-*.pid` names a process that exists.
    static func hasLiveWorker(home: String) -> Bool {
        CursorPaths.workerPIDFiles(home: home).contains { file in
            guard let pid = CursorPaths.workerPID(atPath: file.path) else { return false }
            return CursorWorkerProbe.isProcessAlive(pid: pid)
        }
    }

    // MARK: - Tailing

    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        CursorSessionTailer(source: source, cursor: cursor, clock: clock)
    }

    // MARK: - Liveness

    /// A store (`store.db`), its `meta.json`, a thin transcript, or a worker
    /// pid file. `-wal`/`-shm` siblings belong to a store already tailed and
    /// are routed to it by the coordinator, so they are not new sessions.
    public func mightBeSessionFile(path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == CursorPaths.storeFileName || name == CursorPaths.metaFileName { return true }
        if name.hasSuffix(".jsonl") { return true }
        return name.hasPrefix("cursor-agent-worker-") && name.hasSuffix(".pid")
    }


    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        if let hint = workerHint(identity, table: table, home: home) { return hint }

        let age = Self.ageOfLastWrite(store: identity.sourcePath, now: clock())
        if let age, age <= aliveWithin {
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "store or its WAL written \(Int(age))s ago"
            )
        }

        if let cwd = identity.cwd,
           CursorWorkerProbe.socketAccepts(
               path: CursorPaths.workerSocketPath(home: home, slug: CursorPaths.slug(forCWD: cwd))
           ) {
            return .unknown("a cursor-agent worker is listening for this project; this agent may be idle")
        }

        guard let age else {
            return .unknown("no cursor-agent worker names this agent, and the store could not be stat'd")
        }
        if age > deadAfter {
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "no cursor-agent worker names this agent; store untouched for "
                    + "\(Int(age / 60)) min"
            )
        }
        return .unknown("no cursor-agent worker names this agent; store written \(Int(age))s ago")
    }

    /// A verdict from the worker pid files, or `nil` when none of them names
    /// this agent.
    ///
    /// Two ways a pid is attributed, and the first is exact:
    /// `CURSOR_AGENT_CHAT_ID` is the agent id `cursor-agent` passes to its own
    /// children, so a match is proof. A working-directory match is weaker — a
    /// person may have two agents open on one project — and is only reached
    /// when the environment could not be read, which is what a process this
    /// user does not own looks like.
    ///
    /// A pid file whose process is gone yields nothing rather than `dead`: the
    /// file outlives a crash, and other evidence deserves its turn.
    private func workerHint(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint? {
        for file in CursorPaths.workerPIDFiles(home: home) {
            guard let pid = CursorPaths.workerPID(atPath: file.path),
                  let record = table.record(pid: pid)
            else { continue }

            if table.environment(pid: pid)?[Self.chatIDVariable] == identity.key.sessionID {
                return LivenessHint(
                    verdict: .alive,
                    pid: pid,
                    evidence: "\(record.name) (pid \(pid)) has \(Self.chatIDVariable) for this agent"
                )
            }
            if let cwd = identity.cwd, let processCWD = record.cwd, processCWD == cwd {
                return LivenessHint(
                    verdict: .alive,
                    pid: pid,
                    evidence: "\(record.name) (pid \(pid)) is running in this session's directory"
                )
            }
        }
        return nil
    }

    /// How long ago the store or its WAL was written, whichever is fresher.
    static func ageOfLastWrite(store: String, now: Date) -> TimeInterval? {
        let stamps = [store, store + "-wal"].compactMap { FileStamp.read(path: $0)?.modified }
        guard let latest = stamps.max() else { return nil }
        return now.timeIntervalSince(latest)
    }

    // MARK: - Walking

    /// Directory entries that are themselves directories, never following a
    /// symlink.
    private func subdirectories(of url: URL) -> [URL] {
        DiscoveryIO.children(of: url, options: [.skipsHiddenFiles]).filter(DiscoveryIO.isDirectory)
    }
}
