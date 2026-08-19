import AgentSessionKit
import Foundation

/// The live view of Grok Bot: xAI's standalone desktop client, whose
/// conversations run on xAI's servers and are replicated into one flat
/// directory of JSON blobs.
///
/// ## The store
///
/// ```text
/// ~/Library/Application Support/Grok Bot/sand-client-persistence/
///     <base32(key)>.blob
/// ```
///
/// Every file is named after the lowercase, unpadded RFC 4648 base32 of the
/// key it holds, so the filename *is* the schema. Two keys matter:
/// `sand.client.slice.account.<account>.transcript.replicas.<bot uuid>` is one
/// conversation, and `…roster.last-roster` is the bot list that names it.
/// Everything else under the prefix — `ui-layout`, `composer-drafts`,
/// `send-journal`, `selection.last-agent` — is client chrome and is ignored.
/// There can be more than one account, and the roster is resolved per account.
///
/// This is **not** Grok Build. They share a company and nothing else: one is a
/// local CLI with rollouts on disk, the other a cloud bot whose client caches
/// conversations. Grok Bot's local executor does run the `grok` binary, in a
/// sandbox directory of its own, and those processes belong to neither
/// harness's session list.
///
/// ## A cloud cache, so partial by nature
///
/// There are no tool calls, no model, no token counts, and no working
/// directory anywhere in this format — the run happened server-side. Sessions
/// therefore have no `cwd`, and a host that groups by project has to give them
/// a home of its own rather than infer one.
///
/// ## Liveness
///
/// A conversation on a server does not end; a *client* stops watching it. So
/// the question this probe answers is whether the client is up:
///
/// - No `Grok Bot` process and no fresh supervisor heartbeat → **dead**, for
///   every conversation at once. Nothing local is going to move.
/// - Client up and the replica written within ``aliveWithin`` → **alive**.
/// - Client up and quiet → ``LivenessHint/Verdict/unknown``, however long the
///   quiet has lasted. A bot nobody has spoken to since Tuesday is *idle*, and
///   calling it dead while its client sits there ready to answer would be a
///   different and wrong claim.
public struct GrokBotLiveAdapter: SourceAdapter {
    public let harness: Harness = .grokBot

    /// The client's own executable, inside its bundle. Matched by path
    /// component rather than by an `/Applications` prefix, so an install
    /// somewhere else is still recognised.
    public static let applicationComponent = "/Grok Bot.app/Contents/MacOS/"

    /// The short process name the kernel reports for the main binary. The
    /// Electron helpers carry names of their own and are not asked about.
    public static let processName = "Grok Bot"

    /// How recently a replica must have been written for the write alone to
    /// mean the conversation is live.
    ///
    /// Two minutes. The client rewrites a replica on every step of a streaming
    /// reply, so anything actually happening touches the file far more often
    /// than this; a longer window would keep finished conversations lit.
    public let aliveWithin: TimeInterval

    /// How recently the supervisor must have written its heartbeat for the
    /// heartbeat alone to mean the client is up.
    ///
    /// The file is rewritten every few seconds, so a two-minute window is
    /// generous and still cannot outlive a client that quit.
    public let heartbeatWithin: TimeInterval

    /// How long a conversation must be quiet before the evidence string calls
    /// it idle rather than merely recent.
    ///
    /// It never produces ``LivenessHint/Verdict/dead``: the conversation is on
    /// xAI's servers and goes on existing whether or not this Mac wrote to it.
    public let idleAfter: TimeInterval

    private let clock: @Sendable () -> Date

    /// Creates an adapter.
    ///
    /// - Parameters:
    ///   - aliveWithin: See ``aliveWithin``.
    ///   - heartbeatWithin: See ``heartbeatWithin``.
    ///   - idleAfter: See ``idleAfter``.
    ///   - clock: The observation clock, injected so the suite does not have
    ///     to wait for real time to pass.
    public init(
        aliveWithin: TimeInterval = 120,
        heartbeatWithin: TimeInterval = 120,
        idleAfter: TimeInterval = 600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.aliveWithin = aliveWithin
        self.heartbeatWithin = heartbeatWithin
        self.idleAfter = idleAfter
        self.clock = clock
    }

    // MARK: - Watching

    /// The one directory, watched whole. It is flat and holds a couple of
    /// dozen files.
    ///
    /// `~/.grokbot` is deliberately *not* watched. The only file in it this
    /// package reads is the supervisor heartbeat, which is rewritten every few
    /// seconds and is consumed by ``probeLiveness(_:table:home:)`` on the
    /// liveness resolver's own tick; subscribing would wake the host
    /// continuously for a signal nothing in the ingest path consumes. Its
    /// neighbours hold a daemon token and a credential, and this package has
    /// no business subscribing to those either.
    public func watchRoots(home: String) -> [URL] {
        [GrokBotStore.root(home: home)]
    }

    // MARK: - Discovery

    /// Every conversation worth tailing, one per transcript replica.
    ///
    /// A replica is included when the blob itself was written since the
    /// cutoff, when the roster says the bot was active since the cutoff — the
    /// two clocks disagree in both directions — or when the roster says the
    /// bot is `awaitingUserResponse`, whatever its timestamps say. A
    /// conversation blocked on a person is the one row a board must never
    /// drop, and it has been blocked for exactly as long as nobody answered.
    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        let directory = GrokBotStore.root(home: home)
        var rosters: [String: (url: URL, rows: [String: GrokBotSessionAdapter.RosterRow])] = [:]
        var sources: [SessionSource] = []

        for blob in Self.blobs(in: directory) {
            guard let key = GrokBotSessionAdapter.transcriptKey(at: blob) else { continue }
            if rosters[key.accountID] == nil {
                rosters[key.accountID] = GrokBotStore.roster(
                    accountID: key.accountID, in: directory)
            }
            let roster = rosters[key.accountID]
            let row = roster?.rows[key.botID]
            guard Self.isActive(blob: blob, row: row, activeSince: activeSince) else { continue }
            sources.append(source(blob: blob, key: key, row: row, rosterPath: roster?.url.path))
        }
        return sources.sorted { $0.key.sessionID < $1.key.sessionID }
    }

    /// Whether a conversation has moved recently enough to be worth a tailer.
    static func isActive(
        blob: URL,
        row: GrokBotSessionAdapter.RosterRow?,
        activeSince: Date
    ) -> Bool {
        if row?.awaitingUserResponse == true { return true }
        if let activity = row?.lastActivityAt, activity >= activeSince { return true }
        guard let modified = FileStamp.read(path: blob.path)?.modified else { return false }
        return modified >= activeSince
    }

    /// Builds a source, seeded with everything the roster could say cheaply.
    ///
    /// The roster is an auxiliary path rather than a second source: a change
    /// to it is a change to this session — the name moved, or the *needs you*
    /// flag flipped — and the tailer reads both files on one poll.
    private func source(
        blob: URL,
        key: GrokBotSessionAdapter.TranscriptKey,
        row: GrokBotSessionAdapter.RosterRow?,
        rosterPath: String?
    ) -> SessionSource {
        let sessionKey = SessionKey(harness: harness, sessionID: key.botID)
        var identity = SessionIdentity(key: sessionKey, sourcePath: blob.path)
        identity.variant = GrokBotSessionAdapter.variant
        identity.entrypoint = Self.entrypoint
        identity.title = row?.name
        // `cwd`, `model`, and every counter stay `nil`: the conversation ran
        // on xAI's servers and this directory records none of them.
        return SessionSource(
            key: sessionKey,
            primaryPath: blob.path,
            auxiliaryPaths: rosterPath.map { [$0] } ?? [],
            seedIdentity: identity
        )
    }

    /// ``SessionIdentity/entrypoint`` for every conversation here. There is
    /// only the one surface: the desktop client.
    public static let entrypoint = "desktop"

    /// `*.blob` directly inside the store, never following a symlink.
    static func blobs(in directory: URL) -> [URL] {
        DiscoveryIO.children(
            of: directory,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == GrokBotSessionAdapter.blobExtension }
    }

    // MARK: - Tailing

    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        GrokBotTranscriptTailer(source: source, cursor: cursor, clock: clock)
    }

    /// A `.blob` inside a `sand-client-persistence` directory whose name
    /// decodes to a transcript key.
    ///
    /// Name-only, as this must be: it runs on every path in every filesystem
    /// notification. Decoding the stem is what keeps the roster out — the
    /// client rewrites that file constantly, and treating each write as "a
    /// conversation appeared" would run discovery in a loop.
    public func mightBeSessionFile(path: String) -> Bool {
        guard GrokBotStore.isBlob(path: path) else { return false }
        return GrokBotSessionAdapter.transcriptKey(at: URL(fileURLWithPath: path)) != nil
    }

    // MARK: - Liveness

    /// Decides whether the client behind `identity` is still there.
    ///
    /// See the type's discussion: the verdict is about the *client*, because
    /// the conversation itself is not on this machine. `dead` therefore means
    /// "Grok Bot is not running" and is answered for every conversation at
    /// once, while a running client with a quiet conversation answers
    /// ``LivenessHint/Verdict/unknown`` however long the quiet has lasted.
    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        let now = clock()
        guard let client = client(table: table, home: home, now: now) else {
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "Grok Bot is not running and its supervisor left no fresh heartbeat"
            )
        }

        guard let modified = FileStamp.read(path: identity.sourcePath)?.modified else {
            return .unknown("\(client.evidence); this conversation's replica could not be stat'd")
        }
        let age = now.timeIntervalSince(modified)
        if age <= aliveWithin {
            return LivenessHint(
                verdict: .alive,
                pid: client.pid,
                evidence: "\(client.evidence); replica written \(Int(max(0, age))) s ago"
            )
        }
        if age > idleAfter {
            return .unknown(
                "\(client.evidence); this conversation has been quiet for \(Int(age / 60)) min")
        }
        return .unknown("\(client.evidence); replica written \(Int(age)) s ago")
    }

    /// Evidence that the desktop client is up, with its pid when the process
    /// table named one.
    ///
    /// The process is asked first and the heartbeat second. A process is the
    /// stronger answer and carries a pid; the heartbeat covers the case where
    /// the table cannot be read for another user's or a differently installed
    /// binary, and it cannot outlive the client that writes it by more than
    /// ``heartbeatWithin``.
    func client(table: any ProcessTableReading, home: String, now: Date) -> (pid: pid_t?, evidence: String)? {
        if let process = table.find(where: Self.isClient).min(by: { $0.pid < $1.pid }) {
            return (process.pid, "Grok Bot is running (pid \(process.pid))")
        }
        if let heartbeat = GrokBotStore.heartbeat(home: home) {
            let age = now.timeIntervalSince(heartbeat.at)
            if age <= heartbeatWithin, age > -heartbeatWithin {
                return (nil, "the Grok Bot supervisor wrote a heartbeat \(Int(max(0, age))) s ago")
            }
        }
        return nil
    }

    /// Whether a process is the client's main binary.
    ///
    /// Only the main binary. The Electron helpers — renderer, GPU, the crash
    /// handler — come and go, and one of them being up is not evidence that
    /// the app the person sees is.
    static func isClient(_ record: ProcessRecord) -> Bool {
        if record.executablePath.hasSuffix(applicationComponent + processName) { return true }
        return record.executablePath.isEmpty && record.name == processName
    }
}
