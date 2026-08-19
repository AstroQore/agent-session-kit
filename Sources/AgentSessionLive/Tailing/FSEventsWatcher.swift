import AgentSessionKit
import CoreServices
import Darwin
import Dispatch
import Foundation

/// One delivery from the file-system watcher: the paths that changed since
/// the last delivery, coalesced.
///
/// FSEvents reports the same path several times inside one callback when a
/// harness writes, flushes, and updates metadata in the same instant. A
/// batch keeps each path once, with the flags OR-ed together and the highest
/// event id seen for it — everything a consumer can act on, and nothing it
/// would have to deduplicate itself.
///
/// `paths` preserves first-sighting order, so a consumer that polls in order
/// polls the file that changed first, first.
public struct FSEventBatch: Hashable, Sendable {
    /// Each changed path once, in the order it was first seen in the batch.
    public let paths: [String]
    /// The OR of every flag FSEvents reported for a path in this batch.
    public let flagsByPath: [String: FSEventStreamEventFlags]
    /// The highest event id reported for a path in this batch. A host that
    /// persists one can ask FSEvents to replay from it after a relaunch.
    public let eventIDs: [String: FSEventStreamEventId]

    /// Creates a batch. The dictionaries are expected to be keyed by the
    /// entries of `paths`.
    public init(
        paths: [String],
        flagsByPath: [String: FSEventStreamEventFlags],
        eventIDs: [String: FSEventStreamEventId]
    ) {
        self.paths = paths
        self.flagsByPath = flagsByPath
        self.eventIDs = eventIDs
    }

    /// Whether FSEvents said the item at `path` is itself a directory.
    ///
    /// Only meaningful with ``FSEventsWatcher/CreateFlags/fileEvents``, which
    /// is what makes FSEvents report per-item flags at all. Without it every
    /// delivered path *is* a directory and none is flagged as one, so this
    /// answers `false` throughout — and a consumer that skips directories
    /// correctly stops skipping when directories are all it is being told
    /// about.
    public func isDirectory(_ path: String) -> Bool {
        guard let flags = flagsByPath[path] else { return false }
        return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    }

    /// `true` when FSEvents said it dropped events and the consumer should
    /// re-scan rather than trust the path list.
    ///
    /// Both flags mean the same thing to a tailer: something changed that is
    /// not in `paths`. A coordinator answers by re-polling everything it
    /// tails and re-running discovery.
    public var demandsRescan: Bool {
        let mustRescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let kernelDrop = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        let userDrop = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        return flagsByPath.values.contains { $0 & (mustRescan | kernelDrop | userDrop) != 0 }
    }
}

/// A recursive file-system watch over a set of roots, delivered as an
/// `AsyncStream` of coalesced batches.
///
/// ## Roots that do not exist yet
///
/// `FSEventStreamCreate` accepts a path that is not there, but the stream it
/// returns is inert: nothing is delivered when the path finally appears,
/// because FSEvents resolved the path once at creation. That is exactly the
/// case this package lives in — a person installs a harness after the board
/// is already running, and `~/.grok/sessions` springs into existence an hour
/// into the session.
///
/// So the watcher never watches a root directly. It watches each root's
/// **nearest existing ancestor** and filters what comes back down to the
/// declared roots, and it re-checks on a timer: when a root that used to be
/// missing appears, the resolved ancestor set changes and the whole stream is
/// rebuilt around the narrower paths. A caller that passed
/// `~/.grok/sessions` on a machine with no `~/.grok` gets a watch on `~`
/// until the directory shows up, and a watch on `~/.grok/sessions` after.
///
/// Watching an ancestor is wider than asked for, which is why the filter is
/// not optional: a consumer never sees a path outside the roots it declared.
///
/// ## Threading
///
/// Everything happens on a private serial queue. `start()` and `stop()` are
/// safe from any thread and are idempotent. The FSEvents callback holds a
/// retained reference to an internal sink — not to the watcher — so the
/// watcher is free to deallocate, and its `deinit` tears the stream down and
/// finishes the async stream.
public final class FSEventsWatcher: @unchecked Sendable {
    // `@unchecked` because Swift cannot see the queue discipline: every
    // stored property below is either a `let` of a Sendable type or is read
    // and written exclusively on `queue` (marked "queue-confined"). The one
    // exception is `deinit`, which by definition cannot race with anything
    // still holding a reference.

    /// The FSEvents stream-creation flags this watcher understands.
    ///
    /// A thin option set over the `kFSEventStreamCreateFlag*` constants, so
    /// that a caller does not have to reach into CoreServices to pick a
    /// combination, and so the default can be named.
    public struct CreateFlags: OptionSet, Hashable, Sendable {
        public let rawValue: FSEventStreamCreateFlags

        public init(rawValue: FSEventStreamCreateFlags) {
            self.rawValue = rawValue
        }

        /// Report individual files rather than the directories containing
        /// them. Without this a transcript append arrives as "something in
        /// this directory changed" and the coordinator has to stat every
        /// file it tails there.
        public static let fileEvents = CreateFlags(
            rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        /// Deliver the first event of a burst immediately instead of waiting
        /// out the latency window. Turn-by-turn latency is the whole point of
        /// this layer.
        public static let noDefer = CreateFlags(
            rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        /// Report when a watched root is itself moved or deleted, so the
        /// watcher can re-resolve instead of watching a path that no longer
        /// means anything.
        public static let watchRoot = CreateFlags(
            rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        /// Drop events this process caused. The library only reads, but a
        /// host that writes its index next to a store should not wake itself.
        ///
        /// Worth knowing before it costs an afternoon: this drops writes made
        /// by *this process*, which includes writes made by a test. A watcher
        /// created with the default flags reports nothing about a file the
        /// same program just wrote, and that looks exactly like FSEvents
        /// being broken. Anything that writes its own fixtures should leave
        /// this flag out — see ``IngestConfiguration/watcherFlags``.
        public static let ignoreSelf = CreateFlags(
            rawValue: FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf))

        /// `[.fileEvents, .noDefer, .watchRoot, .ignoreSelf]`.
        public static let `default`: CreateFlags = [.fileEvents, .noDefer, .watchRoot, .ignoreSelf]
    }

    /// The batches this watcher produces. Finished by ``stop()`` and by
    /// `deinit`.
    public let batches: AsyncStream<FSEventBatch>

    /// The roots the watcher was asked for, normalised. Delivered paths are
    /// always one of these or below one of them.
    public let roots: [String]

    private let continuation: AsyncStream<FSEventBatch>.Continuation
    private let latency: TimeInterval
    private let flags: CreateFlags
    private let rearmInterval: TimeInterval
    private let onRestart: (@Sendable () -> Void)?
    private let queue: DispatchQueue

    // Queue-confined below this line.
    private var stream: FSEventStreamRef?
    private var resolved: [ResolvedRoot] = []
    private var rearmTimer: DispatchSourceTimer?
    private var isStarted = false

    /// Creates a watcher over `paths`.
    ///
    /// - Parameters:
    ///   - paths: The roots to report changes under. They need not exist;
    ///     see the type's discussion of ancestor watching.
    ///   - latency: How long FSEvents coalesces before delivering. The
    ///     default trades a tenth of a second for not waking once per
    ///     `write(2)` while a turn streams.
    ///   - flags: Stream creation flags. See ``CreateFlags/default``.
    ///   - rearmInterval: How often to re-check whether a missing root has
    ///     appeared (or a present one vanished). Only a `stat` per root.
    ///   - onRestart: Called on the watcher's queue after the stream was
    ///     rebuilt, so a coordinator can re-scan what it may have missed
    ///     across the gap.
    public init(
        paths: [String],
        latency: TimeInterval = 0.1,
        flags: CreateFlags = .default,
        rearmInterval: TimeInterval = 2,
        onRestart: (@Sendable () -> Void)? = nil
    ) {
        self.roots = Self.normalise(paths)
        self.latency = latency
        self.flags = flags
        self.rearmInterval = rearmInterval
        self.onRestart = onRestart
        self.queue = DispatchQueue(label: "com.astroqore.AgentSessionLive.fsevents")
        var escapee: AsyncStream<FSEventBatch>.Continuation!
        self.batches = AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { escapee = $0 }
        self.continuation = escapee
    }

    deinit {
        // No other reference exists, so nothing can be running on `queue`
        // that touches `self`: every queued block captures the watcher
        // weakly, and a weak read after deallocation begins yields `nil`.
        rearmTimer?.cancel()
        if let stream { Self.tearDown(stream) }
        continuation.finish()
    }

    /// Starts watching. Idempotent: a second call while running does
    /// nothing.
    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.rebuildLocked(notifyRestart: false)
            self.startRearmTimerLocked()
        }
    }

    /// Stops watching and finishes ``batches``. Idempotent, and a stopped
    /// watcher cannot be restarted — the stream it published is already
    /// finished, and handing a caller a dead stream is worse than making
    /// them build a new watcher.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.rearmTimer?.cancel()
            self.rearmTimer = nil
            if let stream = self.stream { Self.tearDown(stream) }
            self.stream = nil
            self.resolved = []
            self.continuation.finish()
        }
    }

    /// The paths FSEvents is actually subscribed to right now: the
    /// canonicalised nearest existing ancestor of each declared root.
    /// Exposed for tests and diagnostics.
    public func currentWatchPaths() -> [String] {
        queue.sync { Self.watchPaths(of: resolved) }
    }

    // MARK: - Queue-confined

    private func startRearmTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + rearmInterval, repeating: rearmInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.isStarted else { return }
            if Self.resolve(self.roots) != self.resolved {
                self.rebuildLocked(notifyRestart: true)
            }
        }
        rearmTimer = timer
        timer.resume()
    }

    private func rebuildLocked(notifyRestart: Bool) {
        if let stream {
            Self.tearDown(stream)
            self.stream = nil
        }

        let resolved = Self.resolve(roots)
        self.resolved = resolved
        let watchPaths = Self.watchPaths(of: resolved)
        guard !watchPaths.isEmpty else { return }

        // The sink is what the C callback actually holds. Keeping the
        // watcher out of the callback context is what lets `deinit` run at
        // all: a retained `self` in the context would be a cycle that no
        // amount of `stop()` discipline could break.
        let sink = Sink(roots: resolved) { [weak self] batch in
            guard let self else { return }
            self.continuation.yield(batch)
            // A root that just came into existence narrows the watch. Never
            // rebuild from inside the callback the stream is delivering —
            // hop to the next turn of the same serial queue instead.
            self.queue.async { [weak self] in
                guard let self, self.isStarted else { return }
                if Self.resolve(self.roots) != self.resolved {
                    self.rebuildLocked(notifyRestart: true)
                }
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Sink>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Sink>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            watchPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags.rawValue
        ) else {
            KitLog.warn("FSEventsWatcher: stream creation failed for \(watchPaths.count) root(s)")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            KitLog.warn("FSEventsWatcher: stream start failed for \(watchPaths.count) root(s)")
            return
        }
        stream = created
        if notifyRestart { onRestart?() }
    }

    private static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    // MARK: - Path arithmetic

    /// One declared root, as the filesystem and FSEvents actually see it.
    ///
    /// The three forms are all different and all necessary, because FSEvents
    /// reports **canonical** paths: a caller who asked about
    /// `/var/folders/…/store` gets told about `/private/var/folders/…/store`,
    /// since `/var` is a symlink. Filtering the declared form against a
    /// canonical delivery matches nothing at all, which is a bug that looks
    /// exactly like "FSEvents is not working".
    ///
    /// So the watcher filters against ``canonical`` and hands the consumer
    /// paths rewritten back under ``declared``. Whatever vocabulary a caller
    /// used for its roots is the vocabulary its batches arrive in, and an
    /// adapter's `primaryPath` still matches the path in the batch.
    struct ResolvedRoot: Hashable, Sendable {
        /// The path the caller passed in, normalised.
        let declared: String
        /// The same path with every existing component resolved. Equal to
        /// ``declared`` on a filesystem with no symlinks above the root.
        let canonical: String
        /// The nearest existing directory at or above ``canonical`` — the
        /// path FSEvents is actually given.
        let watch: String
    }

    /// Trailing slashes removed, duplicates removed, order preserved.
    /// Nothing is resolved against the filesystem here: a root that does not
    /// exist must survive normalisation intact.
    static func normalise(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for path in paths {
            var trimmed = path
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Resolves every declared root against the filesystem as it is now.
    ///
    /// The result is compared against the previous one on a timer, so it must
    /// be a total function of the filesystem state: when a missing root
    /// appears, `watch` narrows from an ancestor to the root itself, the
    /// arrays stop being equal, and the stream is rebuilt.
    static func resolve(_ roots: [String]) -> [ResolvedRoot] {
        roots.compactMap { root in
            guard let ancestor = nearestExistingDirectory(root) else { return nil }
            let canonicalAncestor = realPath(ancestor) ?? ancestor
            let suffix = String(root.dropFirst(ancestor.count))
            return ResolvedRoot(
                declared: root,
                canonical: canonicalAncestor + suffix,
                watch: canonicalAncestor
            )
        }
    }

    /// The deduplicated set of paths to hand FSEvents, with anything already
    /// covered by another entry removed.
    ///
    /// Handing FSEvents both `/a` and `/a/b` is legal but doubles the
    /// delivery of everything under `/a/b`, so the narrower entry is dropped.
    static func watchPaths(of resolved: [ResolvedRoot]) -> [String] {
        // Sorted so a covering ancestor is always seen before what it covers.
        let sorted = Array(Set(resolved.map(\.watch))).sorted()
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { isPath(path, underOrEqualTo: $0) }) {
            kept.append(path)
        }
        return kept
    }

    /// Walks up from `path` until something exists and is a directory.
    /// Returns `nil` only if even `/` is unreachable.
    static func nearestExistingDirectory(_ path: String) -> String? {
        var candidate = path
        while true {
            var buffer = stat()
            if stat(candidate, &buffer) == 0, buffer.st_mode & S_IFMT == S_IFDIR {
                return candidate
            }
            guard candidate != "/", candidate.contains("/") else { return nil }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != candidate else { return nil }
            candidate = parent
        }
    }

    /// `realpath(3)`, or `nil` when the path cannot be resolved.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    /// `true` when `path` is `root` itself or lives beneath it. String
    /// arithmetic only: a filesystem round trip per delivered path would
    /// undo the point of the watch.
    static func isPath(_ path: String, underOrEqualTo root: String) -> Bool {
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    /// Holds everything the C callback needs, and nothing that would keep
    /// the watcher alive.
    fileprivate final class Sink {
        /// Sorted longest-canonical-first, so a nested root wins over the
        /// root that contains it and the rewrite uses the most specific
        /// declared prefix.
        let roots: [ResolvedRoot]
        let deliver: (FSEventBatch) -> Void

        init(roots: [ResolvedRoot], deliver: @escaping (FSEventBatch) -> Void) {
            self.roots = roots.sorted { $0.canonical.count > $1.canonical.count }
            self.deliver = deliver
        }

        /// Coalesces one FSEvents callback into a batch: drops paths outside
        /// the declared roots, and rewrites the rest back into the caller's
        /// own path vocabulary.
        func consume(
            paths rawPaths: [String],
            flags: [FSEventStreamEventFlags],
            ids: [FSEventStreamEventId]
        ) {
            var ordered: [String] = []
            var flagsByPath: [String: FSEventStreamEventFlags] = [:]
            var idsByPath: [String: FSEventStreamEventId] = [:]

            for (index, raw) in rawPaths.enumerated() {
                guard let path = rewrite(raw) else { continue }
                let flag = index < flags.count ? flags[index] : 0
                let identifier = index < ids.count ? ids[index] : 0
                if flagsByPath[path] == nil {
                    ordered.append(path)
                    flagsByPath[path] = flag
                    idsByPath[path] = identifier
                } else {
                    flagsByPath[path]! |= flag
                    idsByPath[path] = max(idsByPath[path] ?? 0, identifier)
                }
            }
            guard !ordered.isEmpty else { return }
            deliver(FSEventBatch(paths: ordered, flagsByPath: flagsByPath, eventIDs: idsByPath))
        }

        /// A canonical path from FSEvents, expressed under the declared root
        /// that contains it, or `nil` when no declared root does.
        private func rewrite(_ raw: String) -> String? {
            for root in roots where FSEventsWatcher.isPath(raw, underOrEqualTo: root.canonical) {
                return root.declared + String(raw.dropFirst(root.canonical.count))
            }
            return nil
        }
    }
}

/// The C entry point. Kept at file scope because a `FSEventStreamCallback` is
/// a bare function pointer and cannot capture.
private let fsEventsCallback: FSEventStreamCallback = {
    _, info, numEvents, eventPaths, eventFlags, eventIDs in
    guard let info, numEvents > 0 else { return }
    let sink = Unmanaged<FSEventsWatcher.Sink>.fromOpaque(info).takeUnretainedValue()

    // Without `kFSEventStreamCreateFlagUseCFTypes` the paths arrive as a
    // plain `char **`, which is cheaper to read than bridging a CFArray.
    let pathPointers = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []
    var ids: [FSEventStreamEventId] = []
    paths.reserveCapacity(numEvents)
    flags.reserveCapacity(numEvents)
    ids.reserveCapacity(numEvents)

    for index in 0..<numEvents {
        guard let pointer = pathPointers[index] else { continue }
        paths.append(String(decodingCString: pointer, as: UTF8.self))
        flags.append(eventFlags[index])
        ids.append(eventIDs[index])
    }
    sink.consume(paths: paths, flags: flags, ids: ids)
}
