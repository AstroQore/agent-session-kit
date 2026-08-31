import AgentSessionKit
import Foundation
import Synchronization

/// The live view of OpenAI Codex: `~/.codex/sessions`, tailed, with liveness
/// taken from the writer lock rather than guessed from a timestamp.
///
/// ## The store
///
/// One append-only JSONL rollout per thread, at
/// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<stamp>-<uuid>.jsonl`, plus a
/// flat `~/.codex/archived_sessions`. Every Codex surface — the CLI, the
/// VS Code extension, the desktop app, `codex exec`, and every sub-agent any
/// of them spawns — writes into that one tree; only the header's `originator`
/// separates them, and this adapter keeps it in
/// ``SessionIdentity/variant``. The one exception is a guardian / Auto Review
/// rollout, which spends that field on `auto-review:<root session id>` — the
/// same encoding `SessionSummary.providerVariant` carries, so a host has one
/// parse rather than one per layer.
///
/// ## Two harnesses, one store
///
/// One of those surfaces is its own harness. `originator ==
/// "codex_work_desktop"` is ChatGPT **Work** mode in the desktop app, which
/// bills against a different plan and is what a person means by "ChatGPT" and
/// not by "Codex". Discovery therefore keys those rollouts
/// `SessionKey(.chatgptWork, …)` — via `CodexOriginator`, the same mapping
/// the on-disk index uses — and everything downstream follows the source's
/// key: the mapper stamps its events with it, a spawned child inherits it,
/// and ``handledHarnesses`` is what makes a resolver hand this adapter the
/// probe for both. Nothing else in the adapter is harness-aware; the rollout
/// path, the writer lock, and the cursor are all keyed by thread id alone.
///
/// ## Liveness
///
/// Codex takes an advisory lock on
/// `~/.codex/thread-writer-locks/<session id>.lock` for as long as a thread is
/// open, and the kernel releases it however the process ends. That makes it a
/// far better signal than the rollout's mtime, which looks identical for a
/// session thinking hard about one prompt and a session whose process was
/// killed an hour ago. Codex is Rust, so the lock is a `flock(2)` and
/// `F_GETLK` will not name its owner — see
/// ``LockFileProbe/LockState/heldByUnknownOwner``, which this adapter treats
/// as locked, because it is.
///
/// A held lock also overrides the discovery cutoff: a thread opened last
/// month and still running is the single most interesting row on a board, and
/// it would fall outside any mtime window that keeps discovery cheap.
///
/// ## What is not read
///
/// Codex keeps thread titles, cwds, and git branches in a SQLite side index
/// (`~/.codex/sqlite/codex-dev.db`, table `local_thread_catalog`). Reading a
/// database another process holds open needs `AgentSessionKit`'s
/// `LiveSQLiteReader`, which is internal to that module; until it is public,
/// a title arrives the way the rollout gives it — from
/// `event_msg.thread_name_updated`, mid-tail. TODO: seed `title` and
/// `gitBranch` at discovery from the catalog once the reader is reachable.
public struct CodexLiveAdapter: SourceAdapter {
    public let harness: Harness = .codex

    /// Both harnesses that write into `~/.codex/sessions`.
    ///
    /// ChatGPT Work is not a second store, a second format, or a second
    /// process — it is the same Codex writing the same rollouts from the
    /// desktop app's Work mode, and the only thing separating the two is the
    /// header's `originator`. So one adapter discovers, tails, and probes
    /// both, and says so here rather than leaving every ChatGPT Work session
    /// without a liveness probe.
    public let handledHarnesses: [Harness] = [.codex, .chatgptWork]

    /// Rollouts, relative to a home directory.
    public static let sessionsPath = ".codex/sessions"
    /// Archived rollouts. Flat, not date-partitioned.
    public static let archivedPath = ".codex/archived_sessions"
    /// One `<session id>.lock` per open thread.
    public static let locksPath = ".codex/thread-writer-locks"

    /// How long a rollout with no writer lock must go untouched before the
    /// session behind it is called dead.
    ///
    /// Ten minutes, because the lock file is the real signal and this is only
    /// the answer for a Codex old enough not to have written one. Short enough
    /// that a board does not show yesterday's session as maybe-alive, long
    /// enough that a model chewing on a hard prompt is not buried.
    public static let deadAfter: TimeInterval = 10 * 60

    /// How many lines of a rollout discovery reads to seed an identity.
    ///
    /// A forked thread replays its ancestors' headers first, and the model
    /// only appears in the first `turn_context`, so the window has to clear
    /// both. Twelve lines covers every rollout on the corpus this was built
    /// against; a wider window would be read for every file on the machine.
    static let seedLines = 12

    private let linker: CodexSubagentLinker

    /// Seeds already built, keyed by rollout path and stamped with the inode
    /// and size the head was read at.
    ///
    /// Discovery runs every few seconds and reads the head of every recent
    /// rollout to seed an identity; the head — `session_meta` with its
    /// multi-kilobyte instructions block — never changes once written, so
    /// decoding it again on every pass is what turned discovery into a hot
    /// loop on a machine with a hundred recent threads. A rollout that has
    /// grown still yields the same seed; one whose inode changed is a
    /// different file and is re-read.
    private let seedCache = CodexSeedCache()

    /// Where the whole-tree walk found the rollout for a locked thread, and
    /// which locked threads have no rollout at all. See the second pass of
    /// ``discover(home:activeSince:under:)``.
    private let rolloutIndex = CodexRolloutIndex()

    /// Creates an adapter.
    ///
    /// - Parameter linker: Where parent → child edges are remembered. Shared
    ///   between the tailers this adapter builds and its own discovery; a
    ///   caller passes its own only to inspect it.
    public init(linker: CodexSubagentLinker = CodexSubagentLinker()) {
        self.linker = linker
    }

    /// The spawn edges seen so far. Exposed so a host can attach a child that
    /// was discovered before its parent's transcript was read.
    public var subagentLinker: CodexSubagentLinker { linker }

    // MARK: - Watching

    /// Both rollout trees and the lock directory.
    ///
    /// The locks are watched, not just polled, because a lock being taken or
    /// released is the moment a session's liveness changes and there is no
    /// other file-system event that says so — a thread can be opened and sit
    /// idle without a byte being appended to its rollout.
    public func watchRoots(home: String) -> [URL] {
        [Self.sessionsPath, Self.archivedPath, Self.locksPath].map {
            URL(fileURLWithPath: home).appendingPathComponent($0)
        }
    }

    // MARK: - Discovery

    /// Every rollout worth tailing: those written since `activeSince`, plus
    /// every thread whose writer lock is held right now, whatever its age.
    ///
    /// Bounded by construction. The tree is `<yyyy>/<MM>/<dd>`, so a date
    /// older than the cutoff is skipped by *directory name* — a machine with
    /// three years of transcripts costs three years of `readdir` on the day
    /// directories, and zero `stat`s inside them. The one wider walk is for a
    /// locked session whose rollout is not in the recent window, which is rare
    /// and is exactly the session a board must not lose.
    ///
    /// One day of slack on the cutoff, because a rollout's directory is named
    /// for local midnight and `activeSince` is an instant; without it, a
    /// session started at 23:58 disappears two minutes later.
    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        try await discover(home: home, activeSince: activeSince, under: nil)
    }

    /// The same, over one day directory when a notification named one.
    ///
    /// A rollout is created in, and only ever appended to, the day directory
    /// named for the local midnight its thread opened at, so a change under
    /// `<root>/2026/08/19` is news about that day and about nothing else. A
    /// change anywhere else under the roots — the lock directory, a year, a
    /// month, a root itself — falls through to the full pass.
    public func discover(
        home: String,
        activeSince: Date,
        under directory: URL?
    ) async throws -> [SessionSource] {
        if let day = Self.dayDirectory(home: home, under: directory) {
            return rollouts(in: day, since: activeSince)
                .sorted { $0.key < $1.key }
                .compactMap { source(sessionID: $0.key, file: $0.value) }
        }

        let directories = scanDirectories(home: home)
        let floor = Calendar.current.startOfDay(for: activeSince).addingTimeInterval(-86_400)

        // Pass one: recent day directories, recently written files.
        var candidates: [String: URL] = [:]
        for directory in directories where directory.date.map({ $0 >= floor }) ?? true {
            candidates.merge(rollouts(in: directory.url, since: activeSince)) { _, new in new }
        }

        // Pass two: anything holding a writer lock is alive by definition, so
        // it is discovered even if it has not been written to in a month.
        //
        // The walk that needs is the whole tree, every year of it, and the
        // ids that reach it are the ones no recent pass could account for —
        // which, on a machine carrying lock files left behind by threads
        // whose rollouts are long gone, is the same set every single time. So
        // the walk's answers are kept: where an id's rollout turned out to
        // be, and which ids have no rollout anywhere. A thread whose rollout
        // appears later is found by pass one, on the notification that
        // creates it.
        let unresolved = rolloutIndex.resolve(heldLocks(home: home).subtracting(candidates.keys))
        for (sessionID, path) in unresolved.known {
            candidates[sessionID] = URL(fileURLWithPath: path)
        }
        if !unresolved.unknown.isEmpty {
            var found: [String: String] = [:]
            for directory in directories {
                for file in rolloutFiles(in: directory.url) {
                    guard let sessionID = Self.sessionID(inFilename: file),
                          unresolved.unknown.contains(sessionID)
                    else { continue }
                    candidates[sessionID] = file
                    found[sessionID] = file.path
                }
            }
            rolloutIndex.record(found: found, missing: unresolved.unknown.subtracting(found.keys))
        }

        return candidates
            .sorted { $0.key < $1.key }
            .compactMap { source(sessionID: $0.key, file: $0.value) }
    }

    /// The rollouts directly inside one directory written since
    /// `activeSince`, keyed by thread id.
    private func rollouts(in directory: URL, since activeSince: Date) -> [String: URL] {
        var out: [String: URL] = [:]
        for file in rolloutFiles(in: directory) {
            guard let sessionID = Self.sessionID(inFilename: file) else { continue }
            guard let modified = FileStamp.read(path: file.path)?.modified,
                  modified >= activeSince
            else { continue }
            out[sessionID] = file
        }
        return out
    }

    /// The `<yyyy>/<MM>/<dd>` directory a scope names, or `nil` for any other
    /// scope — including `nil` itself, which means "sweep".
    ///
    /// Shape only: three components of the right widths, all digits, below a
    /// root this adapter declared. A directory somebody dropped in there and
    /// called `notes` falls through to the full pass rather than being walked
    /// as if it were a day.
    static func dayDirectory(home: String, under directory: URL?) -> URL? {
        guard let directory else { return nil }
        let path = directory.path
        for root in [sessionsPath, archivedPath] {
            let rootPath = URL(fileURLWithPath: home).appendingPathComponent(root).path
            guard DiscoveryIO.path(path, isUnder: rootPath), path != rootPath else { continue }
            let relative = path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
            guard relative.count == 3,
                  relative[0].count == 4, relative[1].count == 2, relative[2].count == 2,
                  relative.allSatisfy({ $0.allSatisfy(\.isNumber) })
            else { return nil }
            return directory
        }
        return nil
    }

    /// Builds a source by reading the head of a rollout.
    ///
    /// Returns `nil` when the header names a different thread than the
    /// filename does. That disagreement means the file is not the rollout it
    /// claims to be, and every downstream key — the cursor, the lock path, the
    /// parent edge — is derived from the id, so guessing which half to trust
    /// would key a session on the wrong thread rather than skip a file.
    private func source(sessionID: String, file: URL) -> SessionSource? {
        let inode = FileStamp.read(path: file.path)?.inode
        if let inode, let cached = seedCache.lookup(path: file.path, inode: inode) {
            // The parent edge is the one thing about a seed that can be
            // learned after the head was read: a child discovered before its
            // parent's spawn line was tailed. Re-ask the linker on every hit.
            guard var source = cached, source.seedIdentity.parent == nil,
                  let link = linker.link(forChild: sessionID)
            else { return cached }
            var identity = source.seedIdentity
            identity.parent = link.parent
            identity.parentLink = .subagent(toolUseID: link.toolUseID)
            source = SessionSource(
                key: source.key,
                primaryPath: source.primaryPath,
                auxiliaryPaths: source.auxiliaryPaths,
                seedIdentity: identity
            )
            return source
        }
        let built = buildSource(sessionID: sessionID, file: file)
        if let inode { seedCache.store(built, path: file.path, inode: inode) }
        return built
    }

    private func buildSource(sessionID: String, file: URL) -> SessionSource? {
        DiscoveryIO.countFileRead()
        let head = JSONLHeadTail.headLines(url: file, count: Self.seedLines)
            .compactMap(CodexRolloutRecord.decode)
        let meta = head.first { $0.type == "session_meta" }?.payload

        if let headerID = meta?.firstString("id", "session_id"),
           headerID.caseInsensitiveCompare(sessionID) != .orderedSame {
            return nil
        }

        // The header's `originator` is the *only* thing that separates a
        // ChatGPT Work thread from an ordinary Codex one; they share the
        // tree, the file name, and every record shape. `CodexOriginator`
        // owns the mapping so the live layer and the on-disk index agree —
        // and it deliberately keeps anything unrecognised, including a
        // rollout with no header at all, on the Codex harness rather than
        // inventing ChatGPT Work usage.
        let originator = meta?["originator"]?.string
        let harness = CodexOriginator.harness(originator: originator)

        let key = SessionKey(harness: harness, sessionID: sessionID)
        var identity = SessionIdentity(key: key, sourcePath: file.path)
        identity.cwd = meta?["cwd"]?.string
        identity.variant = originator
        identity.entrypoint = entrypoint(meta)
        identity.model = head.first { $0.type == "turn_context" }?.payload["model"]?.string

        // A guardian rollout says what it is in the same place the on-disk
        // index does, so a host can recognise an Auto Review run through one
        // parse whichever layer handed it the session. The originator is
        // displaced rather than kept alongside: `providerVariant` on a
        // `SessionSummary` is already this and only this, and a second
        // encoding would be a second thing to keep in step.
        let autoReviewRoot = Self.autoReviewRootID(meta: meta, model: identity.model)
        if let autoReviewRoot {
            identity.variant = CodexSessionAdapter.autoReviewVariantPrefix + autoReviewRoot
        }

        if let link = linker.link(forChild: sessionID) {
            identity.parent = link.parent
            identity.parentLink = .subagent(toolUseID: link.toolUseID)
        } else if let rootID = meta?["session_id"]?.string ?? autoReviewRoot,
                  rootID.caseInsensitiveCompare(sessionID) != .orderedSame {
            // A thread Codex spawned itself keeps its own id in `id` and the
            // thread it belongs to in `session_id`. That names an ancestor
            // rather than necessarily the direct parent, and it carries no
            // call id, so a linker edge — which has both — always wins.
            //
            // `parent_thread_id` is the fallback and only for a guardian run,
            // which is what `autoReviewRootID(meta:model:)` will have fallen
            // back to: on an ordinary thread it can name an intermediate
            // sub-agent, and preferring it would file a review under a middle
            // of a chain rather than under the thread a person started.
            identity.parent = SessionKey(harness: harness, sessionID: rootID)
            identity.parentLink = .subagent(toolUseID: nil)
        }

        return SessionSource(key: key, primaryPath: file.path, seedIdentity: identity)
    }

    /// The root thread a guardian / Auto Review rollout belongs to, or `nil`
    /// for an ordinary one.
    ///
    /// The same two tells `CodexSessionAdapter` reads off a summary, against
    /// the same header: `source.subagent.other == "guardian"`, and the review
    /// runtime — a `thread_source` of `subagent` running the
    /// `codex-auto-review` model. Kept in step with that one by having exactly
    /// the same shape; the encoding they both produce is
    /// ``CodexSessionAdapter/autoReviewVariantPrefix``.
    static func autoReviewRootID(meta: CodexJSON?, model: String?) -> String? {
        guard let meta else { return nil }
        let isGuardian = meta["source"]?["subagent"]?["other"]?.string?.lowercased() == "guardian"
        let isReviewRuntime = meta["thread_source"]?.string?.lowercased() == "subagent"
            && model?.lowercased() == "codex-auto-review"
        guard isGuardian || isReviewRuntime else { return nil }
        return meta.firstString("session_id", "parent_thread_id")
    }

    private func entrypoint(_ meta: CodexJSON?) -> String? {
        guard let meta else { return nil }
        guard let source = meta["source"] else { return meta["originator"]?.string }
        if let value = source.string { return value }
        if let members = source.object, let key = members.keys.sorted().first { return key }
        return meta["originator"]?.string
    }

    // MARK: - Tailing

    /// A ``JSONLTailer`` over the rollout, decoding through
    /// ``CodexRecordMapper``.
    ///
    /// The decode closure also feeds every spawn edge it sees to the linker,
    /// which is what lets a child's identity be seeded with its parent when
    /// discovery reaches it.
    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        let key = source.key
        let linker = self.linker
        return JSONLTailer(source: source, cursor: cursor) { data, _ in
            let events = CodexRecordMapper.events(from: data, session: key, now: Date())
            linker.record(events)
            return events
        }
    }

    // MARK: - Liveness

    /// Reads the thread's writer lock.
    ///
    /// The lock is the authority: it is held for exactly as long as the thread
    /// is open, and the kernel drops it when the process dies however it died.
    /// `table` is consulted only to name the process behind a lock the kernel
    /// did attribute — it never overturns the lock's answer, because a pid
    /// missing from a table snapshot assembled a moment ago is a race, not a
    /// death.
    ///
    /// With no lock file at all, there is nothing left but the rollout's
    /// mtime, and the verdict is honest about that: dead once it is older than
    /// ``deadAfter``, and ``LivenessHint/Verdict/unknown`` while it is fresh.
    /// A rollout (`rollout-*.jsonl`) or a writer lock appearing — the two
    /// files that mean a thread opened. `~/.codex/sessions` holds nothing
    /// else, but the lock directory is shared with locks for threads already
    /// tailed, so the name is checked rather than assumed.
    public func mightBeSessionFile(path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { return true }
        return name.hasSuffix(".lock")
    }


    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        let lock = Self.lockPath(home: home, sessionID: identity.key.sessionID)
        switch LockFileProbe.lockState(path: lock) {
        case let .held(pid):
            let process = table.record(pid: pid)?.name
            let evidence = process.map { "thread-writer-lock held by \($0) (pid \(pid))" }
                ?? "thread-writer-lock held by pid \(pid)"
            return LivenessHint(verdict: .alive, pid: pid, evidence: evidence)

        case .heldByUnknownOwner:
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "thread-writer-lock held; flock(2) owners are not named by the kernel"
            )

        case .unlocked:
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "thread-writer-lock present but released"
            )

        case .unreadable:
            guard let age = LockFileProbe.ageOfLastWrite(path: identity.sourcePath) else {
                return .unknown("no thread-writer-lock, and the rollout could not be read")
            }
            if age > Self.deadAfter {
                return LivenessHint(
                    verdict: .dead,
                    pid: nil,
                    evidence: "no thread-writer-lock; rollout untouched for \(Int(age / 60)) min"
                )
            }
            return .unknown("no thread-writer-lock; rollout written \(Int(age)) s ago")
        }
    }

    /// The writer lock for one thread.
    public static func lockPath(home: String, sessionID: String) -> String {
        URL(fileURLWithPath: home)
            .appendingPathComponent(locksPath)
            .appendingPathComponent("\(sessionID).lock")
            .path
    }

    // MARK: - Walking

    /// A directory that may hold rollouts, and the day it is named for.
    ///
    /// `date` is `nil` for a root itself — `archived_sessions` is flat, and an
    /// undated directory is never skipped by the cutoff.
    private struct ScanDirectory {
        let url: URL
        let date: Date?
    }

    /// Every directory under both roots that could hold a rollout.
    ///
    /// Names only: three `readdir`s deep, no `stat` on a file, no read of one.
    private func scanDirectories(home: String) -> [ScanDirectory] {
        var out: [ScanDirectory] = []
        var components = DateComponents()
        let calendar = Calendar.current
        for root in [Self.sessionsPath, Self.archivedPath] {
            let url = URL(fileURLWithPath: home).appendingPathComponent(root)
            out.append(ScanDirectory(url: url, date: nil))
            for year in numericSubdirectories(of: url, digits: 4) {
                for month in numericSubdirectories(of: year.url, digits: 2) {
                    for day in numericSubdirectories(of: month.url, digits: 2) {
                        components.year = year.value
                        components.month = month.value
                        components.day = day.value
                        out.append(
                            ScanDirectory(url: day.url, date: calendar.date(from: components))
                        )
                    }
                }
            }
        }
        return out
    }

    private struct NumericDirectory {
        let url: URL
        let value: Int
    }

    /// Subdirectories whose names are exactly `digits` digits — the `2026`,
    /// `08`, `19` of the rollout tree, and nothing a person dropped in there.
    private func numericSubdirectories(of url: URL, digits: Int) -> [NumericDirectory] {
        children(of: url).compactMap { child in
            let name = child.lastPathComponent
            guard name.count == digits, name.allSatisfy(\.isNumber), let value = Int(name),
                  isDirectory(child)
            else { return nil }
            return NumericDirectory(url: child, value: value)
        }
    }

    private func rolloutFiles(in directory: URL) -> [URL] {
        children(of: directory).filter {
            $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
        }
    }

    /// Directory entries, never following a symlink.
    private func children(of url: URL) -> [URL] {
        DiscoveryIO.children(of: url, options: [.skipsHiddenFiles], sorted: false)
    }

    private func isDirectory(_ url: URL) -> Bool { DiscoveryIO.isDirectory(url) }

    /// The session ids whose writer locks are held right now.
    private func heldLocks(home: String) -> Set<String> {
        let directory = URL(fileURLWithPath: home).appendingPathComponent(Self.locksPath)
        var out: Set<String> = []
        for file in children(of: directory) where file.pathExtension == "lock" {
            guard DiscoveryIO.isLocked(path: file.path) else { continue }
            out.insert(file.deletingPathExtension().lastPathComponent)
        }
        return out
    }

    /// `rollout-2026-08-19T13-58-51-<uuid>.jsonl` → the trailing UUID.
    ///
    /// The stamp in the middle is local time and has its own colons replaced
    /// by dashes, so only the last five dash-separated groups are the id.
    static func sessionID(inFilename url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        let groups = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12],
              candidate.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return candidate
    }
}

/// The seed cache behind ``CodexLiveAdapter``. A class so the value-typed
/// adapter can share one across copies; a `Mutex` because discovery runs off
/// the coordinator's actor.
final class CodexSeedCache: Sendable {
    private struct Entry { let inode: UInt64; let source: SessionSource? }
    private let entries = Mutex<[String: Entry]>([:])

    func lookup(path: String, inode: UInt64) -> SessionSource?? {
        entries.withLock { map in
            guard let entry = map[path], entry.inode == inode else { return nil }
            return .some(entry.source)
        }
    }

    func store(_ source: SessionSource?, path: String, inode: UInt64) {
        entries.withLock { map in
            map[path] = Entry(inode: inode, source: source)
            // Bounded: a machine with a year of rollouts should not keep a
            // year of seeds. Recent files are re-read at most once per eviction.
            if map.count > 512 { map.removeAll() }
        }
    }
}

/// Where the rollout for a thread holding a writer lock lives, once the
/// whole-tree walk has been paid for.
///
/// The second pass of discovery exists for one rare and important case: a
/// thread opened last month, still running, whose rollout is nowhere near the
/// recent window. Finding it costs a walk of every day directory under both
/// roots — three years of them on a working machine.
///
/// The cost is worth paying once and never again, because both answers are
/// stable. A rollout does not move: a thread appends to the file it was
/// created in, in the day directory named for the midnight it opened at. And
/// a lock with no rollout anywhere — the usual reason this pass runs at all,
/// a file left behind by a thread whose rollout was deleted — will not grow
/// one silently; a rollout appearing is a file being created under a watched
/// root, which the first pass sees on the notification.
///
/// A class so the value-typed adapter shares one across its copies, and a
/// `Mutex` because discovery runs off the coordinator's actor.
final class CodexRolloutIndex: Sendable {
    /// What is already known about a set of locked thread ids.
    struct Resolution {
        /// Ids whose rollout was found before, and is still on disk.
        var known: [String: String] = [:]
        /// Ids the tree has to be walked for.
        var unknown: Set<String> = []
    }

    private struct State {
        var found: [String: String] = [:]
        var missing: Set<String> = []
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = limit
    }

    /// Splits `sessionIDs` into what the index can answer and what it cannot.
    ///
    /// A remembered path is re-`stat`ed rather than trusted: a rollout can be
    /// deleted, and handing the coordinator a source over a file that is not
    /// there would cost a tailer error per poll.
    func resolve(_ sessionIDs: Set<String>) -> Resolution {
        guard !sessionIDs.isEmpty else { return Resolution() }
        return state.withLock { state in
            var resolution = Resolution()
            for sessionID in sessionIDs {
                if let path = state.found[sessionID] {
                    if FileStamp.read(path: path) != nil {
                        resolution.known[sessionID] = path
                        continue
                    }
                    state.found[sessionID] = nil
                }
                if state.missing.contains(sessionID) { continue }
                resolution.unknown.insert(sessionID)
            }
            return resolution
        }
    }

    /// Records what a walk turned up, and what it did not.
    func record(found: [String: String], missing: Set<String>) {
        state.withLock { state in
            if state.found.count + state.missing.count > limit {
                state.found.removeAll(keepingCapacity: true)
                state.missing.removeAll(keepingCapacity: true)
            }
            for (sessionID, path) in found {
                state.found[sessionID] = path
                state.missing.remove(sessionID)
            }
            state.missing.formUnion(missing)
        }
    }
}
