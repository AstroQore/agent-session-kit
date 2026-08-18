import AgentSessionKit
import Foundation
import Synchronization

/// The live view of Grok Build: `~/.grok/sessions`, tailed across the several
/// files one session is spread over, with liveness taken from the harness's own
/// registry of running sessions.
///
/// ## The store
///
/// ```text
/// ~/.grok/
///   active_sessions.json                 [{session_id, pid, cwd, opened_at}], `[]` when idle
///   active_sessions.lock
///   sessions/<percent-encoded cwd>/<session id>/
///     events.jsonl                       lifecycle: turns, permissions, phases, MCP
///     updates.jsonl                      the ACP-shaped stream: prompts, prose, tool calls
///     chat_history.jsonl                 the model-facing conversation
///     summary.json                       identity, rewritten in place
///     signals.json                       counters, rewritten in place
///     rewind_points.jsonl, prompt_context.json, system_prompt.txt
///     <file>.lock                        one 0-byte writer lock per mutable file
/// ```
///
/// The directory a session sits in *is* its working directory, percent-encoded
/// — see ``GrokSessionsPath``, which decodes it exactly, unlike Claude Code's
/// lossy project-directory naming. That makes the cwd available before a byte
/// of any transcript is read.
///
/// ## What is tailed
///
/// `events.jsonl` and `updates.jsonl`, merged by timestamp — see
/// ``GrokSessionTailer``. `chat_history.jsonl` is named as an auxiliary path,
/// so a watcher wakes on it and a host can find it, but it is not tailed:
/// every fact in it is in `updates.jsonl` too, stamped, and in a shape that has
/// not changed between releases. ``GrokRecordMapper`` has the table.
///
/// ## Liveness
///
/// Unusually among these harnesses, Grok says so explicitly:
/// `~/.grok/active_sessions.json` is a registry the CLI rewrites under its own
/// lock, holding one `{session_id, pid, cwd, opened_at}` per running session.
/// A session listed there with a pid that is in the process table is alive; one
/// listed with a pid that is not is dead, because the entry outlives a process
/// that was killed rather than allowed to exit.
///
/// Not listed is not the end of it. Grok takes an advisory lock on each mutable
/// file for as long as it has it open, so a held `chat_history.jsonl.lock` is
/// evidence a writer is there even when the registry has not caught up. Grok is
/// Rust, so those are `flock(2)` locks the kernel will not attribute — see
/// ``LockFileProbe/LockState/heldByUnknownOwner``, which this adapter reads as
/// held, because it is. With neither, all that is left is how long the session
/// directory has been quiet.
public struct GrokLiveAdapter: SourceAdapter {
    public let harness: Harness = .grokBuild

    /// Sessions, relative to a home directory.
    public static let sessionsPath = ".grok/sessions"

    /// The registry of running sessions, relative to a home directory.
    public static let activeSessionsPath = GrokActiveSessions.relativePath

    /// The files a session's tailer reads, in the order their events break ties
    /// at equal timestamps.
    ///
    /// `chat_history.jsonl` is deliberately absent; see the type's discussion
    /// and ``GrokRecordMapper``. Tailing it *alongside* `updates.jsonl`
    /// double-counts prompts and prose.
    public static let defaultTailedFiles: [GrokSourceFile] = [.events, .updates]

    /// The files that make up a session, whether or not they are tailed.
    /// Discovery stats these to decide whether a session is recent.
    static let sessionFiles = ["events.jsonl", "updates.jsonl", "chat_history.jsonl", "summary.json"]

    /// How long a session that is neither registered nor holding a lock must go
    /// untouched before it is called dead.
    ///
    /// Ten minutes, for the same reason ``CodexLiveAdapter/deadAfter`` is: the
    /// registry and the locks are the real signals and this is only the answer
    /// when both are silent. Short enough that yesterday's session is not shown
    /// as maybe-alive, long enough that a model chewing on a hard prompt is not
    /// buried.
    public let deadAfter: TimeInterval

    /// Which of a session's files this adapter's tailers read.
    public let tailedFiles: [GrokSourceFile]

    private let options: GrokRecordMapper.Options
    private let clock: @Sendable () -> Date

    /// Creates an adapter.
    ///
    /// - Parameters:
    ///   - deadAfter: See ``deadAfter``.
    ///   - tailedFiles: See ``defaultTailedFiles``.
    ///   - mapperOptions: Passed to ``GrokRecordMapper`` on every line.
    ///   - clock: The observation clock, injected so the suite does not have to
    ///     wait for real time to pass.
    public init(
        deadAfter: TimeInterval = 600,
        tailedFiles: [GrokSourceFile] = GrokLiveAdapter.defaultTailedFiles,
        mapperOptions: GrokRecordMapper.Options = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deadAfter = deadAfter
        self.tailedFiles = tailedFiles
        self.options = mapperOptions
        self.clock = clock
    }

    // MARK: - Watching

    /// The session tree, and the registry file.
    ///
    /// The registry is watched, not just polled, because it changing is the
    /// moment a session's liveness changes and there is no other file-system
    /// event that says so — a session can be started and sit at a prompt
    /// without a byte being appended to any of its files.
    ///
    /// `~/.grok` itself is not watched. It holds the CLI's downloads, its
    /// bundled skills, and a unified log, and a watch there would wake on every
    /// one of them.
    public func watchRoots(home: String) -> [URL] {
        let base = URL(fileURLWithPath: home)
        return [
            base.appendingPathComponent(Self.sessionsPath),
            base.appendingPathComponent(Self.activeSessionsPath)
        ]
    }

    /// `~/.grok/sessions`, for a home directory.
    public static func sessionsRoot(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(sessionsPath)
    }

    // MARK: - Discovery

    /// Every session written to since `activeSince`, plus every session the
    /// registry or a held lock says is running, whatever its age.
    ///
    /// Bounded: two `readdir`s and at most four `stat`s per session directory,
    /// and `summary.json` is read only for a session that passed the cutoff.
    /// Archived sessions (`~/.grok/archived_sessions`, which
    /// `AgentSessionKit`'s `GrokSessionAdapter` does cover) are not walked at
    /// all — a session is archived precisely because nothing is driving it.
    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        let running = Set(
            GrokActiveSessions.read(home: home).compactMap(\.sessionID).map { $0.lowercased() }
        )
        var sources: [SessionSource] = []

        for projectDirectory in children(of: Self.sessionsRoot(home: home)) where isDirectory(projectDirectory) {
            let cwd = GrokSessionsPath.decodeCwd(directoryName: projectDirectory.lastPathComponent)

            for directory in children(of: projectDirectory) where isDirectory(directory) {
                let sessionID = directory.lastPathComponent
                guard !sessionID.isEmpty, !sessionID.hasPrefix(".") else { continue }

                let stamps = Self.sessionFiles.compactMap {
                    FileStamp.read(path: directory.appendingPathComponent($0).path)
                }
                // A directory with none of a session's files in it is not a
                // session, whatever it is named.
                guard !stamps.isEmpty else { continue }

                let isRecent = stamps.contains { $0.modified >= activeSince }
                let isRunning = running.contains(sessionID.lowercased())
                    || Self.heldLock(in: directory) != nil
                guard isRecent || isRunning else { continue }

                guard let source = source(directory: directory, sessionID: sessionID, cwd: cwd) else {
                    continue
                }
                sources.append(source)
            }
        }
        return sources.sorted { $0.key.sessionID < $1.key.sessionID }
    }

    /// Builds a source from a session directory, seeding what `summary.json`
    /// knows.
    ///
    /// Returns `nil` when the summary names a different session than the
    /// directory does. Every downstream key — the cursor, the registry lookup,
    /// the parent edge — is derived from the id, so a disagreement is a
    /// directory that is not the session it claims to be, and guessing which
    /// half to trust would key a session on the wrong id rather than skip it.
    /// A summary that is missing or unparseable is *not* a disagreement: the
    /// directory name is the authority and a session with no summary yet is
    /// simply new.
    private func source(directory: URL, sessionID: String, cwd: String?) -> SessionSource? {
        let summary = GrokSummary.read(path: directory.appendingPathComponent("summary.json").path)
        if let claimed = summary?.sessionID,
           claimed.caseInsensitiveCompare(sessionID) != .orderedSame {
            return nil
        }

        let key = SessionKey(harness: harness, sessionID: sessionID)
        let primary = directory.appendingPathComponent(GrokSourceFile.events.fileName).path
        var identity = SessionIdentity(key: key, sourcePath: primary)
        identity.cwd = cwd ?? summary?.cwd
        identity.title = summary?.title.map { EventText.preview($0, max: 120) }
        identity.model = summary?.model
        // `agent_name` is which bundled agent or persona the session was
        // started as — `grok-build-plan`, `explore` — which is the closest
        // thing the store has to "where this was started from".
        identity.entrypoint = summary?.agentName

        return SessionSource(
            key: key,
            primaryPath: primary,
            auxiliaryPaths: [GrokSourceFile.updates, .chatHistory].map {
                directory.appendingPathComponent($0.fileName).path
            },
            seedIdentity: identity
        )
    }

    // MARK: - Tailing

    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        GrokSessionTailer(
            source: source,
            cursor: cursor,
            files: tailedFiles,
            options: options,
            clock: clock
        )
    }

    // MARK: - Liveness

    /// Registry first, then the writer locks, then the clock.
    ///
    /// `table` overrules the registry in one direction only: a listed pid that
    /// is not running means the entry outlived its process, which is what a
    /// `SIGKILL` leaves behind. It never overrules a *held lock*, because the
    /// kernel does not name a `flock(2)` owner and there is no pid to check.
    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        let sessionID = identity.key.sessionID
        let directory = Self.sessionDirectory(sourcePath: identity.sourcePath)

        if let entry = GrokActiveSessions.read(home: home).first(where: { $0.names(sessionID) }) {
            guard let pid = entry.pid else {
                return LivenessHint(
                    verdict: .alive,
                    pid: nil,
                    evidence: "active_sessions.json lists the session, with no pid on the entry"
                )
            }
            guard let process = table.record(pid: pid) else {
                return LivenessHint(
                    verdict: .dead,
                    pid: pid,
                    evidence: "active_sessions.json lists pid \(pid), which is not in the process table"
                )
            }
            return LivenessHint(
                verdict: .alive,
                pid: pid,
                evidence: "active_sessions.json lists pid \(pid) (\(process.name)), which is running"
            )
        }

        switch Self.heldLock(in: directory) {
        case let .held(pid)?:
            let process = table.record(pid: pid)?.name
            let evidence = process.map { "session lock held by \($0) (pid \(pid))" }
                ?? "session lock held by pid \(pid)"
            return LivenessHint(verdict: .alive, pid: pid, evidence: evidence)

        case .heldByUnknownOwner?:
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "session lock held; flock(2) owners are not named by the kernel"
            )

        case .unlocked?, .unreadable?, nil:
            break
        }

        guard let age = Self.quietFor(directory: directory, now: clock()) else {
            return .unknown("not in active_sessions.json, and the session directory could not be read")
        }
        if age > deadAfter {
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "not in active_sessions.json, no lock held, quiet for \(Int(age / 60)) min"
            )
        }
        return .unknown("not in active_sessions.json, no lock held, written \(Int(age)) s ago")
    }

    // MARK: - Paths and probes

    /// The session directory a source path sits in.
    static func sessionDirectory(sourcePath: String) -> URL {
        let url = URL(fileURLWithPath: sourcePath)
        let name = url.lastPathComponent
        guard name.hasSuffix(".jsonl") || name.hasSuffix(".json") else { return url }
        return url.deletingLastPathComponent()
    }

    /// The state of the first held `*.lock` in a session directory, or `nil`
    /// when nothing there is locked.
    ///
    /// Any of them will do. Grok takes one per mutable file and holds all of
    /// them for the lifetime of the session; which one answers first is an
    /// artefact of directory order, and the question being asked is only
    /// whether a writer is there.
    static func heldLock(in directory: URL) -> LockFileProbe.LockState? {
        for file in children(of: directory) where file.pathExtension == "lock" {
            let state = LockFileProbe.lockState(path: file.path)
            if state.isLocked { return state }
        }
        return nil
    }

    /// How long since anything in the session directory was written, or `nil`
    /// when none of its files could be stat'd.
    static func quietFor(directory: URL, now: Date) -> TimeInterval? {
        let newest = sessionFiles
            .compactMap { FileStamp.read(path: directory.appendingPathComponent($0).path)?.modified }
            .max()
        guard let newest else { return nil }
        return now.timeIntervalSince(newest)
    }

    /// Directory entries, never following a symlink.
    ///
    /// A link inside a session store can resolve anywhere, and this package
    /// does not read anywhere.
    private static func children(of url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: keys).isSymbolicLink) != true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func children(of url: URL) -> [URL] { Self.children(of: url) }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// One session's tailer: a ``JSONLTailer`` per file, merged into one stream.
///
/// A Grok session is not one log. `events.jsonl` carries the turn boundaries
/// and the permission prompts, `updates.jsonl` carries the prompts, the prose,
/// and every tool call with the ids to pair them by, and neither is a superset
/// of the other. So there is a tailer per file and this type owns three things
/// a single-file tailer gets for free:
///
/// - **A cursor that spans them.** ``SourceCursor/composite(_:)`` keyed by path,
///   which is what a host persists and what ``JSONLTailer`` resolves its own
///   entry out of on the way back in. One file rotating re-seeds that file and
///   leaves the others where they were.
/// - **A merge order.** Events come back sorted by the source's own timestamp,
///   with ties broken by the file order and then by position within the file,
///   so the result is deterministic rather than dependent on which tailer was
///   polled first. ``SessionStateReducer`` is order-sensitive — a permission
///   resolved before it was requested leaves a row stuck — and both files stamp
///   to the millisecond, so the merge is the thing that makes the two logs one
///   timeline.
/// - **One sequence.** ``AgentEvent/sequence`` is documented as monotonic per
///   *tailer*, and this is the tailer; the per-file counters underneath would
///   collide. They are re-stamped after the merge.
public final class GrokSessionTailer: SessionTailer {
    public let source: SessionSource

    /// The per-file tailers, in the order that breaks ties at equal timestamps.
    private let tailers: [JSONLTailer]
    private let sequence: Mutex<Int64>

    /// Creates a tailer over the session's files.
    ///
    /// - Parameters:
    ///   - source: The session. `primaryPath` and `auxiliaryPaths` name the
    ///     files; which of them are read is decided by `files`.
    ///   - cursor: Where to resume. A `.composite` is looked up per path by
    ///     each inner tailer; any other shape means cold start for all of them.
    ///   - files: Which of the session's files to read. Defaults to
    ///     ``GrokLiveAdapter/defaultTailedFiles``.
    ///   - options: Passed to ``GrokRecordMapper`` on every line.
    ///   - clock: The observation clock.
    public init(
        source: SessionSource,
        cursor: SourceCursor?,
        files: [GrokSourceFile] = GrokLiveAdapter.defaultTailedFiles,
        options: GrokRecordMapper.Options = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.sequence = Mutex(0)

        let key = source.key
        let directory = GrokLiveAdapter.sessionDirectory(sourcePath: source.primaryPath)
        tailers = files.map { file in
            let path = directory.appendingPathComponent(file.fileName).path
            return JSONLTailer(source: source, path: path, cursor: cursor) { data, _ in
                GrokRecordMapper.events(
                    from: data, file: file, session: key, now: clock(), options: options
                )
            }
        }
    }

    /// One cursor per file, keyed by path.
    public var cursor: SourceCursor {
        .composite(Dictionary(uniqueKeysWithValues: tailers.map { ($0.path, $0.cursor) }))
    }

    /// The files being read, in merge order.
    public var paths: [String] { tailers.map(\.path) }

    public func poll() throws -> [AgentEvent] {
        try merge { try $0.poll() }
    }

    /// Cold start across every file.
    ///
    /// The window is split evenly rather than applied to each file, so a caller
    /// asking for 64 KiB reads 64 KiB in total and not 64 KiB per file. The
    /// files are unequal — `chat_history.jsonl` runs an order of magnitude
    /// larger than `events.jsonl` — but an even split is the one rule that
    /// does not need a stat per file before deciding.
    public func seedFromTail(maxBytes: Int) throws -> [AgentEvent] {
        let budget = max(maxBytes / max(tailers.count, 1), 1)
        return try merge { try $0.seedFromTail(maxBytes: budget) }
    }

    /// Reads every file, merges by timestamp, and re-stamps the sequence.
    private func merge(_ read: (JSONLTailer) throws -> [AgentEvent]) rethrows -> [AgentEvent] {
        var collected: [(file: Int, position: Int, event: AgentEvent)] = []
        for (file, tailer) in tailers.enumerated() {
            for (position, event) in try read(tailer).enumerated() {
                collected.append((file, position, event))
            }
        }
        guard !collected.isEmpty else { return [] }

        collected.sort { lhs, rhs in
            if lhs.event.timestamp != rhs.event.timestamp {
                return lhs.event.timestamp < rhs.event.timestamp
            }
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            return lhs.position < rhs.position
        }

        return sequence.withLock { counter in
            collected.map { item in
                counter += 1
                return AgentEvent(
                    id: item.event.id,
                    session: item.event.session,
                    timestamp: item.event.timestamp,
                    observedAt: item.event.observedAt,
                    sequence: counter,
                    kind: item.event.kind,
                    raw: item.event.raw
                )
            }
        }
    }
}
