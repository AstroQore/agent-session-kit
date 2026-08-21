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
/// `conversation_summaries.db`, and it is the only place a title, a parent
/// conversation, or a busy flag is recorded at all — the IDE writes
/// `agyhub_summaries_proto.pb` instead, which nothing here decodes.
///
/// The workspace is the one fact with more than one source. The summaries
/// store's `workspace_uris` is the conversation's own row and wins; the CLI's
/// `history.jsonl` and its `log/cli-<stamp>.log` answer for the conversations
/// that row never reached, which on a real machine is most of them. See
/// ``AntigravityWorkspaceIndex``. The model has exactly one source, and it is
/// not the one a tailer reads: `gen_metadata`, decoded a few rows deep.
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
    /// The summaries index's rows, keyed by the store and its WAL. See
    /// ``summaries(home:)``.
    private let summaryCache = DiscoveryCache<[FileStamp], [AntigravitySummariesReader.Summary]>()
    /// `conversationId → workspace` from one side file, keyed by that file.
    /// One entry per CLI log plus one for the prompt history, so a run still
    /// being written re-reads and the rest do not. See ``workspaces(home:)``.
    private let workspaceCache = DiscoveryCache<FileStamp, [String: String]>()
    /// The newest model one conversation's `gen_metadata` named, keyed by the
    /// store and its WAL. See ``model(of:)``.
    private let modelCache = DiscoveryCache<[FileStamp], String?>()

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
        try await discover(home: home, activeSince: activeSince, under: nil)
    }

    /// The same, over one root's conversations directory when a notification
    /// named one.
    ///
    /// The two roots are independent stores that happen to share a schema, so
    /// a database appearing under the CLI's says nothing about the IDE's. A
    /// change to the summaries index is not narrowable — `not_fully_idle`
    /// flipping there can make a conversation of *either* root worth tailing
    /// — and sweeps. So does a presence lock being touched, which is the
    /// only sign an attached conversation that has written nothing yet
    /// exists at all.
    public func discover(
        home: String,
        activeSince: Date,
        under directory: URL?
    ) async throws -> [SessionSource] {
        let roots = Self.roots(home: home, under: directory)
        guard !roots.isEmpty else { return [] }

        let summaries = summaries(home: home)
        registry.record(summaries)
        let byID = Dictionary(summaries.map { ($0.conversationID, $0) }, uniquingKeysWith: { a, _ in a })

        var candidates: [String: (url: URL, root: String)] = [:]
        for root in roots {
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

        // The side files are read only when the index left somebody without a
        // workspace, which on a machine whose summaries store is current is
        // never.
        let unattributed = candidates.contains { byID[$0.key]?.workspacePath == nil }
        let fallback = unattributed ? workspaces(home: home) : [:]

        return candidates.sorted { $0.key < $1.key }.map { id, candidate in
            source(
                id: id,
                file: candidate.url,
                root: candidate.root,
                summary: byID[id],
                workspace: fallback[id]
            )
        }
    }

    /// The roots a scope names.
    ///
    /// A scope inside one root's `conversations` directory is that root; a
    /// scope anywhere else under the declared watch roots — the summaries
    /// store, a `presence` directory — is both, because either can carry the
    /// news.
    static func roots(home: String, under directory: URL?) -> [String] {
        guard let directory else { return [cliRoot, ideRoot] }
        let path = directory.path
        for root in [cliRoot, ideRoot] {
            let conversations = conversationsPath(home: home, root: root).path
            if DiscoveryIO.path(path, isUnder: conversations) { return [root] }
        }
        return [cliRoot, ideRoot]
    }

    /// The CLI index's rows, re-read only when the store or its WAL moved.
    ///
    /// Opening somebody else's live SQLite database and walking a table is
    /// the most expensive thing in this adapter, and the answer changes only
    /// when AntiGravity writes — which, in WAL mode, shows up on the `-wal`
    /// sibling rather than on the `.db`, so both are part of the key.
    private func summaries(home: String) -> [AntigravitySummariesReader.Summary] {
        let path = Self.summariesPath(home: home).path
        let version = [FileStamp.version(ofPath: path), .version(ofPath: path + "-wal")]
        return summaryCache.value(path: path, version: version) {
            DiscoveryIO.countFileRead()
            return AntigravitySummariesReader(databaseURL: URL(fileURLWithPath: path)).summaries()
        }
    }

    /// `conversationId → workspace` for the conversations the summaries store
    /// has no `workspace_uris` for.
    ///
    /// Only the CLI root is consulted: the IDE writes neither a prompt history
    /// nor a server log, and a conversation it owns is never named in one of
    /// `agy`'s. Each file is cached against its own mtime, so the one run
    /// still writing is the only one re-read.
    ///
    /// The prompt history is applied last because it is the stronger evidence:
    /// a person typed that prompt in that directory, where a log line only
    /// says which server the conversation belonged to.
    private func workspaces(home: String) -> [String: String] {
        var out: [String: String] = [:]
        let logs = AntigravityWorkspaceIndex.recentLogs(
            in: AntigravityWorkspaceIndex.logDirectory(home: home, root: Self.cliRoot))
        for log in logs {
            let rows = workspaceCache.value(
                path: log.path, version: .version(ofPath: log.path)
            ) {
                DiscoveryIO.countFileRead()
                return AntigravityWorkspaceIndex.logWorkspaces(at: log)
            }
            out.merge(rows) { _, newer in newer }
        }

        let history = AntigravityWorkspaceIndex.historyPath(home: home, root: Self.cliRoot)
        let prompts = workspaceCache.value(
            path: history.path, version: .version(ofPath: history.path)
        ) {
            DiscoveryIO.countFileRead()
            return AntigravityWorkspaceIndex.historyWorkspaces(at: history)
        }
        out.merge(prompts) { _, typed in typed }
        return out
    }

    /// The newest model a conversation's `gen_metadata` named, re-read only
    /// when its store or WAL moved.
    ///
    /// Discovery is where this has to happen. The table is the only place the
    /// model is written down, and ``AntigravityConversationTailer`` reads
    /// `steps` — where a reply and a tool call look the same whichever model
    /// served them.
    private func model(of file: URL) -> String? {
        let path = file.path
        let version = [FileStamp.version(ofPath: path), .version(ofPath: path + "-wal")]
        return modelCache.value(path: path, version: version) {
            DiscoveryIO.countFileRead()
            return AntigravityConversationReader(databaseURL: file).recentModel()
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
        // Five reasons to include a conversation, any one of which is enough,
        // asked cheapest first. The order is free to choose precisely because
        // they are a disjunction — and it matters, because four of these are
        // `stat` calls already half in hand and the fifth is an `open`, an
        // `F_GETLK`, and a `close` on somebody else's presence file. Asking
        // that one first meant paying it for every conversation in the store
        // on every pass, including the ones the mtimes had already settled.
        if summary?.notFullyIdle == true { return true }
        if LockFileProbe.mtimeWithin(path: presence, seconds: Self.presenceFreshWindow) { return true }
        if let modified = summary?.lastModified, modified >= activeSince { return true }
        if let modified = Self.storeModified(path: file.path), modified >= activeSince { return true }
        return DiscoveryIO.isLocked(path: presence)
    }

    /// Builds a source, seeded with everything the index could say cheaply.
    private func source(
        id: String,
        file: URL,
        root: String,
        summary: AntigravitySummariesReader.Summary?,
        workspace: String?
    ) -> SessionSource {
        let key = SessionKey(harness: harness, sessionID: id)
        var identity = SessionIdentity(key: key, sourcePath: file.path)
        identity.variant = root == Self.cliRoot ? Self.cliVariant : Self.ideVariant
        identity.title = summary?.title
        // `workspace_uris` first: it is the conversation's own row. The side
        // files answer for the conversations that row never reached.
        identity.cwd = summary?.workspacePath ?? workspace
        identity.model = model(of: file)
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
        DiscoveryIO.children(of: directory, options: [.skipsHiddenFiles], sorted: false)
            .filter { $0.pathExtension == "db" }
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
