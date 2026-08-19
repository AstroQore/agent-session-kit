import AgentSessionKit
import Foundation

/// The live view of Google AntiGravity: two data roots of per-conversation
/// SQLite databases, tailed by diffing rows rather than by reading new ones.
///
/// ## The store
///
/// Two roots with an identical schema, and the variant is which one a
/// conversation is in:
///
/// ```text
/// ~/.gemini/antigravity-cli/     the `agy` command line          variant "cli"
/// ~/.gemini/antigravity/         the AntiGravity IDE             variant "ide"
/// ```
///
/// (`~/.antigravity` is a different product and is not read.) Each root holds
/// `conversations/<uuid>.db`, a WAL-mode SQLite database per conversation, and
/// `presence/<uuid>.lock`, a zero-byte file whose mtime is touched while the
/// conversation is attached. Only the CLI root has
/// `conversation_summaries.db`, and it is the only place a title, a workspace,
/// a parent conversation, or a busy flag is recorded at all — the IDE writes
/// `agyhub_summaries_proto.pb` instead, which nothing here decodes.
///
/// ## Discovery is a union, not an index lookup
///
/// The summaries store is authoritative about *facts* and unreliable about
/// *membership*: on the corpus this was built against it named a third of the
/// databases actually on disk. So discovery reads it for titles, workspaces,
/// and parents, and then unions it with a walk of both `conversations`
/// directories. A conversation the index forgot is still a conversation, and
/// on a WAL store the mtime that matters is the `-wal` sibling's — the `.db`
/// itself can sit untouched for the whole of a busy hour.
///
/// ## Liveness
///
/// In descending order of how much the evidence is worth: an advisory lock
/// held on the presence file (the kernel drops it however the process dies);
/// an `agy` process whose environment names this conversation (which also
/// yields a pid); a presence file touched seconds ago; the index's own
/// `killed` and `not_fully_idle` flags; and finally the age of the store
/// itself. ``LivenessHint/Verdict/unknown`` is a real answer in between, and
/// the adapter gives it rather than guessing.
public struct AntigravityLiveAdapter: SourceAdapter {
    public let harness: Harness = .antigravity

    /// The `agy` command line's data root, relative to a home directory.
    public static let cliRoot = ".gemini/antigravity-cli"
    /// The AntiGravity IDE's data root.
    public static let ideRoot = ".gemini/antigravity"
    /// One `<uuid>.db` per conversation, inside a root.
    public static let conversationsDirectory = "conversations"
    /// One `<uuid>.lock` per attached conversation, inside a root.
    public static let presenceDirectory = "presence"
    /// The CLI's side index. There is no IDE equivalent this adapter reads.
    public static let summariesFileName = "conversation_summaries.db"

    /// ``SessionIdentity/variant`` for a conversation under ``cliRoot``.
    public static let cliVariant = "cli"
    /// ``SessionIdentity/variant`` for a conversation under ``ideRoot``.
    public static let ideVariant = "ide"

    /// The environment variable `agy` passes its conversation id down in.
    /// Spelled once in ``SessionEnvironmentVariables``, which is also where
    /// the cross-harness linker reads it from.
    public static let conversationEnvironmentKey =
        SessionEnvironmentVariables.antigravityConversationID
    /// The trajectory id passed alongside it. Read for evidence only.
    public static let trajectoryEnvironmentKey =
        SessionEnvironmentVariables.antigravityTrajectoryID
    /// The command line's own executable name.
    public static let processName = "agy"

    /// How recently the presence file must have been touched for its mtime
    /// alone to mean "attached".
    ///
    /// A minute, because the file is touched on a heartbeat rather than on
    /// every write, and because 900 stale lock files from months of past
    /// conversations sat in that directory on the machine this was built
    /// against. An old presence file is not evidence of anything.
    public static let presenceFreshWindow: TimeInterval = 60

    /// How recently the store must have been written for the write alone to
    /// mean "alive".
    public static let storeFreshWindow: TimeInterval = 30

    /// How long an untouched store must go before the conversation behind it
    /// is called dead.
    public static let deadAfter: TimeInterval = 10 * 60

    private let registry: AntigravityConversationRegistry

    /// Creates an adapter.
    ///
    /// - Parameter registry: Where the summaries store's answers are kept
    ///   between a discovery and the tailers and probes that need them. Shared
    ///   by construction; a caller passes its own only to inspect it.
    public init(registry: AntigravityConversationRegistry = AntigravityConversationRegistry()) {
        self.registry = registry
    }

    /// What discovery learned from the CLI's index. Exposed so a host can ask
    /// about a parent edge it saw on an event.
    public var conversationRegistry: AntigravityConversationRegistry { registry }

    // MARK: - Watching

    /// Both roots' `conversations` and `presence` directories, plus the CLI's
    /// summaries store.
    ///
    /// `presence` is watched rather than only polled because a lock file being
    /// touched or removed is the moment a conversation's liveness changes, and
    /// a conversation can be attached and thinking without a byte reaching its
    /// database. The summaries store is watched for the same reason in the
    /// other direction: `killed` and `not_fully_idle` change there and nowhere
    /// else.
    public func watchRoots(home: String) -> [URL] {
        let base = URL(fileURLWithPath: home)
        var roots: [URL] = []
        for root in [Self.cliRoot, Self.ideRoot] {
            let directory = base.appendingPathComponent(root, isDirectory: true)
            roots.append(directory.appendingPathComponent(Self.conversationsDirectory, isDirectory: true))
            roots.append(directory.appendingPathComponent(Self.presenceDirectory, isDirectory: true))
        }
        roots.append(Self.summariesPath(home: home))
        return roots
    }

    /// The CLI's `conversation_summaries.db`.
    public static func summariesPath(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(cliRoot, isDirectory: true)
            .appendingPathComponent(summariesFileName)
    }

    /// The presence lock for one conversation, under the root that owns it.
    public static func presencePath(home: String, root: String, conversationID: String) -> String {
        URL(fileURLWithPath: home)
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent(presenceDirectory, isDirectory: true)
            .appendingPathComponent("\(conversationID).lock")
            .path
    }

    /// The conversations directory of one root.
    public static func conversationsPath(home: String, root: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent(conversationsDirectory, isDirectory: true)
    }

    // MARK: - Discovery

    /// Every conversation worth tailing in either root.
    ///
    /// Three passes, unioned and keyed by conversation id so the same
    /// conversation is never returned twice:
    ///
    /// 1. the CLI index's own recent rows, plus anything it marks busy
    ///    whatever its timestamp says;
    /// 2. a walk of both `conversations` directories, taking the newer of a
    ///    database's own mtime and its `-wal` sibling's;
    /// 3. every conversation whose presence file was touched inside
    ///    ``presenceFreshWindow`` — an attached conversation that has not
    ///    written anything yet is exactly the row a board must not miss.
    ///
    /// A row the index knows about but whose database is not on disk is
    /// dropped: there is nothing to tail.
    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        let summaries = AntigravitySummariesReader(databaseURL: Self.summariesPath(home: home))
            .summaries()
        registry.record(summaries)
        let byID = Dictionary(summaries.map { ($0.conversationID, $0) }, uniquingKeysWith: { a, _ in a })

        var candidates: [String: (url: URL, root: String)] = [:]
        for root in [Self.cliRoot, Self.ideRoot] {
            let directory = Self.conversationsPath(home: home, root: root)
            for file in databases(in: directory) {
                let id = file.deletingPathExtension().lastPathComponent.lowercased()
                guard !id.isEmpty, candidates[id] == nil else { continue }
                let summary = byID[id]
                guard isActive(
                    file: file,
                    summary: summary,
                    presence: Self.presencePath(home: home, root: root, conversationID: id),
                    activeSince: activeSince
                ) else { continue }
                candidates[id] = (file, root)
            }
        }

        return candidates.sorted { $0.key < $1.key }.map { id, candidate in
            source(id: id, file: candidate.url, root: candidate.root, summary: byID[id])
        }
    }

    /// Whether a conversation has done anything recent enough to be worth a
    /// tailer.
    private func isActive(
        file: URL,
        summary: AntigravitySummariesReader.Summary?,
        presence: String,
        activeSince: Date
    ) -> Bool {
        if summary?.notFullyIdle == true { return true }
        if LockFileProbe.isLocked(path: presence) { return true }
        if LockFileProbe.mtimeWithin(path: presence, seconds: Self.presenceFreshWindow) { return true }
        if let modified = summary?.lastModified, modified >= activeSince { return true }
        guard let modified = Self.storeModified(path: file.path) else { return false }
        return modified >= activeSince
    }

    /// Builds a source, seeded with everything the index could say cheaply.
    private func source(
        id: String,
        file: URL,
        root: String,
        summary: AntigravitySummariesReader.Summary?
    ) -> SessionSource {
        let key = SessionKey(harness: harness, sessionID: id)
        var identity = SessionIdentity(key: key, sourcePath: file.path)
        identity.variant = root == Self.cliRoot ? Self.cliVariant : Self.ideVariant
        identity.title = summary?.title
        identity.cwd = summary?.workspacePath
        // The child's own database records only that *a* subtrajectory
        // exists, never whose. The index names the parent from the child's
        // side, and that is the only place the edge is written down.
        if let parent = summary?.parentConversationID?.lowercased(), parent != id {
            identity.parent = SessionKey(harness: harness, sessionID: parent)
            identity.parentLink = .subagent(toolUseID: nil)
        }
        return SessionSource(key: key, primaryPath: file.path, seedIdentity: identity)
    }

    // MARK: - Tailing

    /// A ``AntigravityConversationTailer`` over the conversation database,
    /// sharing this adapter's registry so the parent → child edges discovery
    /// found become events on the parent's stream.
    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        AntigravityConversationTailer(source: source, cursor: cursor, registry: registry)
    }

    // MARK: - Liveness

    /// Decides whether the conversation behind `identity` is attached to a
    /// running AntiGravity.
    ///
    /// The order is the order the evidence deserves. A held lock is the
    /// kernel's own answer and cannot be stale. A process whose environment
    /// names this conversation is nearly as good and carries a pid, which is
    /// what makes the verdict survive pid reuse. Everything after that is a
    /// timestamp, and a timestamp is wrong in both directions on its own — so
    /// a store written a minute ago answers ``LivenessHint/Verdict/unknown``
    /// rather than either verdict.
    /// A conversation store (`conversations/<id>.db`) or the summaries index.
    /// The `-wal`/`-shm` siblings belong to a store already tailed, and the
    /// presence locks are touched continuously by every live conversation —
    /// neither means a conversation appeared.
    public func mightBeSessionFile(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name == Self.summariesFileName { return true }
        guard name.hasSuffix(".db") else { return false }
        return url.deletingLastPathComponent().lastPathComponent == Self.conversationsDirectory
    }


    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        let conversationID = identity.key.sessionID
        let presence = presencePath(for: identity, home: home)

        if LockFileProbe.lockState(path: presence).isLocked {
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "presence lock held; the owner is not named by the kernel"
            )
        }

        if let match = attachedProcess(conversationID: conversationID, table: table) {
            return LivenessHint(
                verdict: .alive,
                pid: match.pid,
                evidence: "\(match.name) (pid \(match.pid)) has \(Self.conversationEnvironmentKey) "
                    + "set to this conversation"
            )
        }

        if let age = LockFileProbe.ageOfLastWrite(path: presence), age <= Self.presenceFreshWindow {
            return LivenessHint(
                verdict: .alive,
                pid: nil,
                evidence: "presence file touched \(Int(max(0, age))) s ago"
            )
        }

        if let entry = registry.entry(for: conversationID) {
            if entry.killed {
                return LivenessHint(
                    verdict: .dead, pid: nil, evidence: "conversation_summaries.killed is set")
            }
            if entry.notFullyIdle {
                return LivenessHint(
                    verdict: .alive,
                    pid: nil,
                    evidence: "conversation_summaries.not_fully_idle is set"
                )
            }
        }

        guard let modified = Self.storeModified(path: identity.sourcePath) else {
            return .unknown("no presence lock, and the conversation store could not be read")
        }
        let age = Date().timeIntervalSince(modified)
        if age <= Self.storeFreshWindow {
            return LivenessHint(
                verdict: .alive, pid: nil, evidence: "conversation store written \(Int(max(0, age))) s ago")
        }
        if age > Self.deadAfter {
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "no presence lock; conversation store untouched for \(Int(age / 60)) min"
            )
        }
        return .unknown("no presence lock; conversation store written \(Int(age)) s ago")
    }

    /// The presence file for a session, in the root its database lives under.
    func presencePath(for identity: SessionIdentity, home: String) -> String {
        let root = identity.variant == Self.ideVariant ? Self.ideRoot : Self.cliRoot
        return Self.presencePath(home: home, root: root, conversationID: identity.key.sessionID)
    }

    /// An `agy` process whose environment names this conversation.
    ///
    /// Only `agy` is asked. The IDE's language server holds every open
    /// conversation at once and names none of them in its environment, so
    /// matching it would say "alive" for every conversation the IDE ever
    /// opened.
    private func attachedProcess(
        conversationID: String,
        table: any ProcessTableReading
    ) -> ProcessRecord? {
        let candidates = table.find { record in
            record.name == Self.processName
                || (record.executablePath as NSString).lastPathComponent == Self.processName
        }
        for record in candidates {
            guard let environment = table.environment(pid: record.pid),
                  let value = environment[Self.conversationEnvironmentKey],
                  value.caseInsensitiveCompare(conversationID) == .orderedSame
            else { continue }
            return record
        }
        return nil
    }

    // MARK: - Walking

    /// `<uuid>.db` files directly inside a conversations directory, never
    /// following a symlink.
    ///
    /// The `-wal` and `-shm` siblings carry the `db-wal` / `db-shm` extension,
    /// so an exact extension match already excludes them.
    private func databases(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { entry in
            entry.pathExtension == "db"
                && (try? entry.resourceValues(forKeys: keys).isSymbolicLink) != true
        }
    }

    /// The newer of a SQLite store's own mtime and its `-wal` sibling's.
    ///
    /// In WAL mode a conversation's whole afternoon can land in `-wal` and
    /// only reach the `.db` on a checkpoint, so the database's own timestamp
    /// routinely says a live session has been idle for hours.
    static func storeModified(path: String) -> Date? {
        let stamps = [path, path + "-wal"].compactMap { FileStamp.read(path: $0)?.modified }
        return stamps.max()
    }
}
