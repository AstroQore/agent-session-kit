import AgentSessionKit
import Foundation

/// Something the ingest pipeline did that a person debugging it would want to
/// know, and that no ``AgentEvent`` can express.
///
/// Deliberately a second stream rather than more ``AgentEventKind`` cases.
/// Events are about *sessions*; these are about the machinery, they have no
/// session to belong to half the time, and a reducer that had to skip over
/// them would be a reducer with opinions about the watcher.
///
/// A host may ignore the stream entirely — nothing here is required for
/// correctness — but a board that never explains why a session stopped
/// updating is a board people stop trusting.
public enum IngestNotice: Hashable, Sendable {
    /// A source appeared and now has a tailer.
    case sourceDiscovered(SessionKey, path: String)
    /// A source stopped being discovered for long enough that its tailer was
    /// released. Its cursor is kept, so it resumes rather than re-seeds if it
    /// comes back.
    case sourceDropped(SessionKey, path: String)
    /// A tailer could not read its source. The read is retried on the next
    /// tick; a source that is permanently broken produces one of these per
    /// poll, which is the intended signal.
    case tailerError(path: String, error: String)
    /// The file-system watch was rebuilt — a watched root appeared, moved, or
    /// vanished. Everything is re-polled and rediscovered afterwards, because
    /// changes during the gap were not delivered.
    case watcherRestarted
}

/// Timings for ``IngestCoordinator``. Every default is a trade between
/// latency and wakeups, and every one of them is wrong for somebody.
public struct IngestConfiguration: Hashable, Sendable {
    /// How long to wait after a file-system notification before polling.
    ///
    /// A streaming turn writes many times a second and a poll per write is
    /// wasted work; 50 ms is under the threshold where a person perceives
    /// lag and above the burst rate of every harness measured.
    public var debounce: Duration
    /// The same, for SQLite stores. Longer because a WAL write is not a
    /// transaction boundary: polling mid-transaction reads nothing and has
    /// to be repeated.
    public var databaseDebounce: Duration
    /// Safety-net poll interval for SQLite-backed sources. Short, because
    /// FSEvents does not reliably report `mmap` stores into an already-sized
    /// `-shm` file, so for these stores the poll is not really a safety net.
    public var sqlitePollEvery: Duration
    /// Safety-net poll interval for file-backed sources. Long, because
    /// FSEvents is reliable for `write(2)` and this only exists to cover a
    /// missed notification.
    public var jsonlPollEvery: Duration
    /// How often every adapter is asked to sweep its whole store again.
    ///
    /// Long, because this is only the safety net. A session that appears
    /// while the pipeline runs is found by routing the file-system
    /// notification to the adapter whose roots contain the path and asking
    /// it about that one directory, which happens in well under a second.
    /// The sweep is for the notification that never came: a store on a
    /// filesystem FSEvents does not report, a watch that was being rebuilt,
    /// a creation that was coalesced away.
    public var rediscoverEvery: Duration
    /// How long a routed, directory-scoped discovery waits for the rest of
    /// its burst before running.
    ///
    /// A turn that writes a transcript, its sidecar, and its lock in the
    /// same millisecond should cost one scoped walk rather than three.
    public var discoveryDebounce: Duration
    /// The floor between two discovery passes of the **same** adapter.
    /// Without it, activity in a directory full of files nobody tails would
    /// run that adapter's discovery continuously.
    public var rediscoverThrottle: Duration
    /// How long a source must go undiscovered before its tailer is dropped.
    public var dropAfter: Duration
    /// How far back discovery looks. A session untouched for longer is not
    /// what a live board is about, and including it costs a tailer.
    public var activeWindow: TimeInterval
    /// Bytes read from the end of a source on cold start.
    public var seedBytes: Int
    /// How often cursors are written when anything moved.
    public var cursorSaveEvery: Duration
    /// Event stream buffer. See ``TailerBackpressure``.
    public var eventBufferSize: Int
    /// Notice stream buffer.
    public var noticeBufferSize: Int
    /// FSEvents coalescing window.
    public var watcherLatency: TimeInterval
    /// FSEvents stream flags.
    ///
    /// Configurable for one reason that matters: the default includes
    /// ``FSEventsWatcher/CreateFlags/ignoreSelf``, and a process that writes
    /// the files it is also watching — a test, or a host that generates
    /// fixtures — is told nothing about its own writes. Drop the flag there.
    public var watcherFlags: FSEventsWatcher.CreateFlags

    /// Creates a configuration. Every parameter defaults to the value
    /// documented on its property.
    public init(
        debounce: Duration = .milliseconds(50),
        databaseDebounce: Duration = .milliseconds(250),
        sqlitePollEvery: Duration = .seconds(2),
        jsonlPollEvery: Duration = .seconds(10),
        rediscoverEvery: Duration = .seconds(60),
        discoveryDebounce: Duration = .milliseconds(250),
        rediscoverThrottle: Duration = .seconds(3),
        dropAfter: Duration = .seconds(600),
        activeWindow: TimeInterval = 24 * 60 * 60,
        seedBytes: Int = JSONLTailer.defaultSeedBytes,
        cursorSaveEvery: Duration = .seconds(2),
        eventBufferSize: Int = TailerBackpressure.defaultEventBufferSize,
        noticeBufferSize: Int = TailerBackpressure.defaultNoticeBufferSize,
        watcherLatency: TimeInterval = 0.1,
        watcherFlags: FSEventsWatcher.CreateFlags = .default
    ) {
        self.debounce = debounce
        self.databaseDebounce = databaseDebounce
        self.sqlitePollEvery = sqlitePollEvery
        self.jsonlPollEvery = jsonlPollEvery
        self.rediscoverEvery = rediscoverEvery
        self.discoveryDebounce = discoveryDebounce
        self.rediscoverThrottle = rediscoverThrottle
        self.dropAfter = dropAfter
        self.activeWindow = activeWindow
        self.seedBytes = seedBytes
        self.cursorSaveEvery = cursorSaveEvery
        self.eventBufferSize = eventBufferSize
        self.noticeBufferSize = noticeBufferSize
        self.watcherLatency = watcherLatency
        self.watcherFlags = watcherFlags
    }

    /// The documented defaults.
    public static let `default` = IngestConfiguration()
}

/// The one thing a host starts: adapters in, a stream of events out.
///
/// ```text
///   SourceAdapter.watchRoots ──▶ FSEventsWatcher ──┐
///   SourceAdapter.discover ───▶ SessionTailer ◀────┤ debounce ──▶ poll()
///                                     │            │
///                            safety-net poll ──────┘
///                                     │
///                                     ▼
///                        AsyncStream<AgentEvent>  +  AsyncStream<IngestNotice>
/// ```
///
/// Five things happen on a schedule, and each covers a hole in the others:
///
/// - **Watch.** One ``FSEventsWatcher`` over the union of every adapter's
///   roots. One watch, not one per harness: FSEvents streams are a per-process
///   resource and eight of them over overlapping trees deliver the same event
///   eight times.
/// - **Debounce.** A notification schedules a poll rather than performing one.
///   A turn that streams for thirty seconds produces one poll per debounce
///   window instead of one per `write(2)`.
/// - **Safety-net poll.** Every tailer is polled on an interval regardless of
///   notifications, because FSEvents drops events under load and does not
///   report WAL writes into a mapped `-shm` at all.
/// - **Routed discovery.** A notification for a path nothing tails goes to the
///   adapters whose declared roots contain it, and asks them about that one
///   directory. This is how a session that started a second ago is found.
/// - **Rediscovery.** Every adapter sweeps its whole store on a long interval,
///   as the safety net for a notification that never arrived.
///
/// ## What it does not do
///
/// It does not reduce, store, or interpret. Events come out in the order the
/// tailers produced them and nothing is dropped inside the pipeline — see
/// ``TailerBackpressure`` for the one place a drop can happen.
public actor IngestCoordinator {
    private struct Entry {
        let source: SessionSource
        let tailer: any SessionTailer
        let isDatabaseBacked: Bool
        var lastPolled: ContinuousClock.Instant?
    }

    /// What one adapter has been asked to look at, as a burst of file-system
    /// notifications accumulates.
    private struct PendingScope {
        /// The directories a changed path was found in.
        var directories: Set<String> = []
        /// The scopes stopped being worth tracking separately — sweep the
        /// adapter's whole store instead. A burst that touches dozens of
        /// directories at once is a store being rewritten, and walking each
        /// of them costs more than one sweep.
        var wholeStore = false
    }

    /// How many distinct directories one adapter is asked about before a
    /// scoped pass is replaced by a sweep.
    private static let maximumScopes = 16

    private let adapters: [any SourceAdapter]
    private let home: String
    private let cursorStore: (any SourceCursorStore)?
    private let configuration: IngestConfiguration
    /// Each adapter's declared watch roots, in the same order as `adapters`.
    ///
    /// The whole of the routing decision: a changed path belongs to the
    /// adapters whose roots contain it, and to no others. Without the
    /// containment test, a rule as innocent as "any `*.lock` could be a
    /// session" — which is true inside `~/.codex` — claims every writer lock
    /// Grok touches and every presence file AntiGravity heartbeats, and every
    /// one of those becomes a sweep of the whole machine.
    private let adapterRoots: [[String]]

    private var watcher: FSEventsWatcher?
    private var entries: [String: Entry] = [:]
    /// Every path worth reacting to → the primary path that owns it.
    private var pathOwner: [String: String] = [:]
    private var lastSeen: [String: ContinuousClock.Instant] = [:]
    private var savedCursors: [String: SourceCursor] = [:]

    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var debounceGeneration: [String: Int] = [:]
    private var inFlight: Set<String> = []

    private var tasks: [Task<Void, Never>] = []
    private var rediscoveryTask: Task<Void, Never>?
    private var rediscoveryPending = false
    private var lastDiscoveryAt: ContinuousClock.Instant?
    /// Directories a routed discovery still owes each adapter, by index.
    private var pendingScopes: [Int: PendingScope] = [:]
    private var scopedDiscoveryTask: Task<Void, Never>?
    /// When each adapter last discovered anything, by index. The throttle is
    /// per adapter because the stores are independent: Grok being rewritten
    /// is no reason to make Claude Code wait.
    private var lastAdapterDiscoveryAt: [Int: ContinuousClock.Instant] = [:]

    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var noticeContinuation: AsyncStream<IngestNotice>.Continuation?
    private var activeStreams: (events: AsyncStream<AgentEvent>, notices: AsyncStream<IngestNotice>)?

    private var isRunning = false
    private var isBootstrapped = false
    private var cursorsDirty = false

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - adapters: One per harness worth watching. An empty array is legal
    ///     and produces a coordinator that watches nothing.
    ///   - home: The home directory every adapter resolves its roots against.
    ///     Explicit, always: the suite runs against synthetic trees and
    ///     nothing in this package may reach for the real `~`.
    ///   - cursorStore: Where to resume from, and where to persist to.
    ///     `nil` means every launch is a cold start.
    ///   - configuration: Timings. See ``IngestConfiguration``.
    public init(
        adapters: [any SourceAdapter],
        home: String,
        cursorStore: (any SourceCursorStore)? = nil,
        configuration: IngestConfiguration = .default
    ) {
        self.adapters = adapters
        self.home = home
        self.cursorStore = cursorStore
        self.configuration = configuration
        // Resolved once: `watchRoots` is a pure function of `home` for every
        // adapter in this package, and routing asks the question per path.
        self.adapterRoots = adapters.map { adapter in
            adapter.watchRoots(home: home).map(\.path)
        }
    }

    /// Starts watching, discovering, and tailing, and returns the two
    /// streams.
    ///
    /// Idempotent: calling it again while running returns the same streams
    /// rather than starting a second pipeline. Both streams are finished by
    /// ``stop()``, and a stopped coordinator cannot be restarted — build
    /// another one.
    ///
    /// Returns immediately. The first events arrive once discovery and the
    /// cold-start seeds have run, which is milliseconds on a normal machine
    /// and longer on one with hundreds of sources.
    @discardableResult
    public func start() -> (events: AsyncStream<AgentEvent>, notices: AsyncStream<IngestNotice>) {
        if let activeStreams { return activeStreams }

        let (events, eventContinuation) = AsyncStream.makeStream(
            of: AgentEvent.self,
            bufferingPolicy: .bufferingNewest(configuration.eventBufferSize)
        )
        let (notices, noticeContinuation) = AsyncStream.makeStream(
            of: IngestNotice.self,
            bufferingPolicy: .bufferingNewest(configuration.noticeBufferSize)
        )
        self.eventContinuation = eventContinuation
        self.noticeContinuation = noticeContinuation
        self.activeStreams = (events, notices)
        isRunning = true

        let roots = adapterRoots.flatMap { $0 }
        let watcher = FSEventsWatcher(
            paths: roots,
            latency: configuration.watcherLatency,
            flags: configuration.watcherFlags,
            onRestart: { [weak self] in
                Task { await self?.handleWatcherRestart() }
            }
        )
        self.watcher = watcher
        watcher.start()

        tasks.append(Task { [weak self] in
            for await batch in watcher.batches {
                guard let self else { return }
                await self.handle(batch: batch)
            }
        })
        tasks.append(Task { [weak self] in await self?.discoveryLoop() })
        tasks.append(Task { [weak self] in await self?.pollLoop() })
        tasks.append(Task { [weak self] in await self?.persistLoop() })

        return (events, notices)
    }

    /// Stops everything, persists cursors one last time, and finishes both
    /// streams.
    ///
    /// Awaits the final cursor save, so a host can `await stop()` in its
    /// shutdown path and know the next launch resumes where this one ended.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        debounceGeneration.removeAll()
        rediscoveryTask?.cancel()
        rediscoveryTask = nil
        scopedDiscoveryTask?.cancel()
        scopedDiscoveryTask = nil
        pendingScopes.removeAll()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        watcher?.stop()
        watcher = nil

        cursorsDirty = true
        await persistCursorsIfDirty()

        entries.removeAll()
        pathOwner.removeAll()
        lastSeen.removeAll()
        inFlight.removeAll()

        eventContinuation?.finish()
        eventContinuation = nil
        noticeContinuation?.finish()
        noticeContinuation = nil
        activeStreams = nil
    }

    /// Every cursor a host would want to persist: the live tailers' current
    /// positions, plus the last known position of every source that has been
    /// dropped since the coordinator started.
    ///
    /// Dropped sources are included on purpose. A harness that goes quiet for
    /// an hour and then resumes should resume, not re-seed.
    public func snapshotCursors() -> [String: SourceCursor] {
        var merged = savedCursors
        for (path, entry) in entries {
            merged[path] = entry.tailer.cursor
        }
        return merged
    }

    /// The sources currently being tailed. Diagnostics and tests.
    public func trackedPaths() -> [String] {
        entries.keys.sorted()
    }

    // MARK: - Discovery

    private func discoveryLoop() async {
        if let cursorStore {
            do {
                savedCursors = try await cursorStore.load()
            } catch {
                noticeContinuation?.yield(
                    .tailerError(path: "<cursor-store>", error: describe(error)))
            }
        }
        isBootstrapped = true

        while !Task.isCancelled, isRunning {
            await performDiscovery()
            do {
                try await Task.sleep(for: configuration.rediscoverEvery)
            } catch {
                return
            }
        }
    }

    /// A full sweep: every adapter, its whole store, followed by the drop
    /// pass.
    ///
    /// The drop pass belongs here and nowhere else. "This source stopped
    /// being discovered" is only meaningful after somebody looked everywhere,
    /// and a scoped pass looked at one directory.
    private func performDiscovery() async {
        guard isRunning else { return }
        lastDiscoveryAt = ContinuousClock.now
        let cutoff = Date().addingTimeInterval(-configuration.activeWindow)

        for index in adapters.indices {
            await discover(adapterAt: index, cutoff: cutoff, under: nil)
        }

        let now = ContinuousClock.now
        for (path, seen) in lastSeen where now - seen > configuration.dropAfter {
            drop(path)
        }
    }

    /// Runs one adapter's discovery, over one directory or over everything,
    /// and registers whatever came back that is not already tailed.
    private func discover(adapterAt index: Int, cutoff: Date, under directories: Set<String>?) async {
        guard isRunning, adapters.indices.contains(index) else { return }
        let adapter = adapters[index]
        lastAdapterDiscoveryAt[index] = ContinuousClock.now
        // Cleared before the walk, not after: a file that appears while the
        // walk is running has to survive as a pending scope, or the one
        // notification announcing it is thrown away.
        if directories == nil { pendingScopes[index] = nil }

        let scopes: [URL?] = directories.map { $0.sorted().map { URL(fileURLWithPath: $0) } } ?? [nil]
        for scope in scopes {
            let sources: [SessionSource]
            do {
                // Off the actor: an adapter's discovery is a directory walk
                // with no suspension points of its own, and run inline it
                // would hold the actor — and every poll and watch event
                // behind it — for as long as the walk takes.
                let home = self.home
                sources = try await Task.detached(priority: .utility) {
                    try await adapter.discover(home: home, activeSince: cutoff, under: scope)
                }.value
            } catch {
                noticeContinuation?.yield(
                    .tailerError(path: adapter.harness.rawValue, error: describe(error)))
                continue
            }
            for source in sources {
                lastSeen[source.primaryPath] = ContinuousClock.now
                guard entries[source.primaryPath] == nil else { continue }
                await register(source, adapter: adapter)
            }
        }
    }

    private func register(_ source: SessionSource, adapter: any SourceAdapter) async {
        let cursor = savedCursors[source.primaryPath]
        let tailer: any SessionTailer
        do {
            tailer = try adapter.makeTailer(source, cursor: cursor)
        } catch {
            noticeContinuation?.yield(
                .tailerError(path: source.primaryPath, error: describe(error)))
            return
        }

        let isDatabaseBacked = source.allPaths.contains(where: SQLiteChangeWatcher.isStoreFile)
        entries[source.primaryPath] = Entry(
            source: source,
            tailer: tailer,
            isDatabaseBacked: isDatabaseBacked,
            lastPolled: nil
        )
        for path in source.allPaths {
            pathOwner[path] = source.primaryPath
            // A SQLite store is three files, and the one that moves during a
            // turn is almost never the one the adapter named.
            if SQLiteChangeWatcher.isStoreFile(path) {
                pathOwner[path + "-wal"] = source.primaryPath
                pathOwner[path + "-shm"] = source.primaryPath
            }
        }
        noticeContinuation?.yield(.sourceDiscovered(source.key, path: source.primaryPath))

        // Hand the adapter's seed identity to the host before the first line
        // is tailed. Discovery is the only place a pid, a parent, or a cwd
        // decoded from a directory name is known, and a tail that begins
        // mid-transcript would otherwise never learn them. The reducer treats
        // a `sessionStarted` for a session it already tracks as an identity
        // merge, so re-registering after a drop does not reset anything.
        eventContinuation?.yield(Self.seedEvent(for: source))

        let seedBytes = configuration.seedBytes
        if cursor == nil {
            await execute(path: source.primaryPath) {
                try await tailer.seedFromTail(maxBytes: seedBytes)
            }
        } else {
            await execute(path: source.primaryPath) {
                try await tailer.poll()
            }
        }
    }

    /// The `sessionStarted` a freshly registered source contributes.
    ///
    /// Stamped with the best "when did this begin" available without reading
    /// the source: the process start when the adapter knows it, else the
    /// primary file's creation date, else now — so a session discovered on
    /// cold start is not reported as having begun the moment Auspex launched.
    static func seedEvent(for source: SessionSource) -> AgentEvent {
        let identity = source.seedIdentity
        let now = Date()
        let began = identity.procStart ?? FileStamp.creationDate(atPath: source.primaryPath) ?? now
        return AgentEvent(
            session: source.key,
            timestamp: began,
            observedAt: now,
            sequence: 0,
            kind: .sessionStarted(identity: identity),
            raw: RawRef(path: source.primaryPath, byteOffset: 0, rowID: nil, lineNumber: nil)
        )
    }

    private func drop(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        lastSeen[path] = nil
        for watched in entry.source.allPaths {
            pathOwner[watched] = nil
            pathOwner[watched + "-wal"] = nil
            pathOwner[watched + "-shm"] = nil
        }
        debounceTasks[path]?.cancel()
        debounceTasks[path] = nil
        debounceGeneration[path] = nil
        // Keep the cursor. A session that went quiet for an hour and came
        // back should resume, not replay.
        savedCursors[path] = entry.tailer.cursor
        cursorsDirty = true
        noticeContinuation?.yield(.sourceDropped(entry.source.key, path: path))
    }

    private func requestRediscovery() {
        guard isBootstrapped, isRunning, !rediscoveryPending else { return }
        rediscoveryPending = true

        var wait = Duration.zero
        if let lastDiscoveryAt {
            let elapsed = ContinuousClock.now - lastDiscoveryAt
            if elapsed < configuration.rediscoverThrottle {
                wait = configuration.rediscoverThrottle - elapsed
            }
        }
        rediscoveryTask?.cancel()
        rediscoveryTask = Task { [weak self] in
            if wait > .zero {
                do { try await Task.sleep(for: wait) } catch { return }
            }
            await self?.runRequestedDiscovery()
        }
    }

    private func runRequestedDiscovery() async {
        rediscoveryPending = false
        await performDiscovery()
    }

    // MARK: - Routed discovery

    /// Records that `path` changed, and that nothing tails it.
    ///
    /// Two questions decide what it costs. *Whose store is this?* — answered
    /// by the adapter's own declared roots, so a lock file under `~/.grok`
    /// never reaches the Codex adapter however much its name looks like a
    /// Codex lock. *Could it be a session?* — the adapter's own
    /// ``SourceAdapter/mightBeSessionFile(path:)``, which keeps the sidecars
    /// every store rewrites continuously from counting as news.
    ///
    /// A path no adapter claims costs nothing at all: no discovery, no
    /// timer, no wakeup.
    private func route(changed path: String) {
        for index in adapters.indices {
            guard adapterRoots[index].contains(where: { DiscoveryIO.path(path, isUnder: $0) }),
                  adapters[index].mightBeSessionFile(path: path)
            else { continue }

            var scope = pendingScopes[index] ?? PendingScope()
            if !scope.wholeStore {
                scope.directories.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                if scope.directories.count > Self.maximumScopes {
                    scope.wholeStore = true
                    scope.directories.removeAll()
                }
            }
            pendingScopes[index] = scope
        }
    }

    /// Schedules the pending scoped passes, debounced and throttled.
    ///
    /// The wait is the *soonest* any pending adapter may run again, so one
    /// adapter sitting out its throttle never delays another. Adapters still
    /// inside their throttle when the pass runs keep their pending scopes and
    /// are rescheduled.
    private func scheduleScopedDiscovery() {
        guard isBootstrapped, isRunning, scopedDiscoveryTask == nil, !pendingScopes.isEmpty else {
            return
        }
        let now = ContinuousClock.now
        var soonest: Duration?
        for index in pendingScopes.keys {
            var remaining = Duration.zero
            if let last = lastAdapterDiscoveryAt[index] {
                let elapsed = now - last
                if elapsed < configuration.rediscoverThrottle {
                    remaining = configuration.rediscoverThrottle - elapsed
                }
            }
            soonest = soonest.map { Swift.min($0, remaining) } ?? remaining
        }
        let wait = Swift.max(configuration.discoveryDebounce, soonest ?? .zero)

        scopedDiscoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            await self?.runScopedDiscovery()
        }
    }

    private func runScopedDiscovery() async {
        scopedDiscoveryTask = nil
        guard isRunning else { return }
        let cutoff = Date().addingTimeInterval(-configuration.activeWindow)
        let now = ContinuousClock.now

        for (index, scope) in pendingScopes.sorted(by: { $0.key < $1.key }) {
            if let last = lastAdapterDiscoveryAt[index], now - last < configuration.rediscoverThrottle {
                continue
            }
            pendingScopes[index] = nil
            await discover(
                adapterAt: index,
                cutoff: cutoff,
                under: scope.wholeStore ? nil : scope.directories
            )
        }
        // Whatever was still inside its throttle, and whatever arrived while
        // this pass was walking.
        scheduleScopedDiscovery()
    }

    // MARK: - Watching

    private func handle(batch: FSEventBatch) async {
        guard isRunning else { return }

        if batch.demandsRescan {
            // FSEvents admitted it dropped something. The path list is no
            // longer a description of what changed, so re-poll everything.
            for (path, entry) in entries {
                schedule(path, database: entry.isDatabaseBacked)
            }
            requestRediscovery()
            return
        }

        for path in batch.paths {
            if let owner = pathOwner[path] {
                schedule(owner, database: SQLiteChangeWatcher.isStoreFile(path))
            } else {
                // Something changed under a watched root that nothing tails:
                // most likely a session that started a moment ago. Route it
                // to whoever owns that part of the disk rather than asking
                // everybody to look everywhere.
                route(changed: path)
            }
        }
        scheduleScopedDiscovery()
    }

    private func handleWatcherRestart() async {
        guard isRunning else { return }
        noticeContinuation?.yield(.watcherRestarted)
        for (path, entry) in entries {
            schedule(path, database: entry.isDatabaseBacked)
        }
        requestRediscovery()
    }

    // MARK: - Polling

    /// Schedules a debounced poll of `path`, replacing any poll already
    /// waiting for it. Trailing-edge: the poll happens `debounce` after the
    /// *last* notification, which is what makes a streaming turn cost one
    /// read instead of two hundred.
    private func schedule(_ path: String, database: Bool) {
        guard isRunning, entries[path] != nil else { return }
        let generation = (debounceGeneration[path] ?? 0) + 1
        debounceGeneration[path] = generation
        let delay = database ? configuration.databaseDebounce : configuration.debounce

        debounceTasks[path]?.cancel()
        debounceTasks[path] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.fireDebounced(path, generation: generation)
        }
    }

    private func fireDebounced(_ path: String, generation: Int) async {
        guard debounceGeneration[path] == generation else { return }
        debounceTasks[path] = nil
        guard let tailer = entries[path]?.tailer else { return }
        await execute(path: path) { try await tailer.poll() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard isRunning else { return }
            let now = ContinuousClock.now
            for (path, entry) in entries {
                let interval = entry.isDatabaseBacked
                    ? configuration.sqlitePollEvery
                    : configuration.jsonlPollEvery
                if let last = entry.lastPolled, now - last < interval { continue }
                let tailer = entry.tailer
                await execute(path: path) { try await tailer.poll() }
            }
        }
    }

    /// Runs one tailer read off the actor and yields what it produced.
    ///
    /// Off the actor because a tailer read is blocking file I/O, and an actor
    /// that blocks its executor on a hundred-megabyte transcript stalls every
    /// other session's poll behind it. The `inFlight` guard is what keeps two
    /// reads of the same source from interleaving — a debounced poll and a
    /// safety-net poll routinely collide.
    private func execute(
        path: String,
        _ work: @escaping @Sendable () async throws -> [AgentEvent]
    ) async {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        defer {
            inFlight.remove(path)
            entries[path]?.lastPolled = ContinuousClock.now
        }
        do {
            let events = try await Task.detached(priority: .utility) { try await work() }.value
            guard !events.isEmpty else { return }
            for event in events { eventContinuation?.yield(event) }
            cursorsDirty = true
        } catch {
            noticeContinuation?.yield(.tailerError(path: path, error: describe(error)))
        }
    }

    // MARK: - Cursors

    private func persistLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.cursorSaveEvery)
            } catch {
                return
            }
            guard isRunning else { return }
            await persistCursorsIfDirty()
        }
    }

    private func persistCursorsIfDirty() async {
        guard cursorsDirty, let cursorStore else { return }
        cursorsDirty = false
        let cursors = snapshotCursors()
        do {
            try await cursorStore.save(cursors)
            savedCursors = cursors
        } catch {
            // Put the flag back: a save that failed is still owed.
            cursorsDirty = true
            noticeContinuation?.yield(.tailerError(path: "<cursor-store>", error: describe(error)))
        }
    }

    private func describe(_ error: any Error) -> String {
        KitLog.sanitize(String(describing: error))
    }
}
