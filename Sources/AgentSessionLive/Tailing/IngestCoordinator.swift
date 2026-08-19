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
    /// How often every adapter is asked to discover again.
    public var rediscoverEvery: Duration
    /// The floor between two discovery passes when one was triggered early
    /// by an unrecognised path. Without it, activity in a directory full of
    /// files nobody tails would run discovery continuously.
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
        rediscoverEvery: Duration = .seconds(15),
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
/// Four things happen on a schedule, and each covers a hole in the others:
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
/// - **Rediscovery.** Every adapter is asked again on an interval, because a
///   new session is a new *file*, and a tailer for it can only exist after
///   something looked.
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

    private let adapters: [any SourceAdapter]
    private let home: String
    private let cursorStore: (any SourceCursorStore)?
    private let configuration: IngestConfiguration

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

        let roots = adapters.flatMap { $0.watchRoots(home: home) }.map(\.path)
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

    private func performDiscovery() async {
        guard isRunning else { return }
        lastDiscoveryAt = ContinuousClock.now
        let cutoff = Date().addingTimeInterval(-configuration.activeWindow)

        for adapter in adapters {
            let sources: [SessionSource]
            do {
                // Off the actor: an adapter's discovery is a directory walk
                // with no suspension points of its own, and run inline it
                // would hold the actor — and every poll and watch event
                // behind it — for as long as the walk takes.
                let home = self.home
                sources = try await Task.detached(priority: .utility) {
                    try await adapter.discover(home: home, activeSince: cutoff)
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

        let now = ContinuousClock.now
        for (path, seen) in lastSeen where now - seen > configuration.dropAfter {
            drop(path)
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

        var sawUnknownPath = false
        for path in batch.paths {
            if let owner = pathOwner[path] {
                schedule(owner, database: SQLiteChangeWatcher.isStoreFile(path))
            } else if !sawUnknownPath, adapters.contains(where: { $0.mightBeSessionFile(path: path) }) {
                // Only a path that could *be* a session earns a rediscovery.
                // Stores write sidecars constantly — summaries, locks, tool
                // output — and each of those used to restart discovery.
                sawUnknownPath = true
            }
        }
        // Something changed under a watched root that nothing tails: most
        // likely a session that started a moment ago.
        if sawUnknownPath { requestRediscovery() }
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
