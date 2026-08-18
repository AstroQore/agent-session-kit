import Dispatch
import Foundation
import Synchronization

/// Notices that a SQLite store another process holds open has changed.
///
/// Cursor and AntiGravity keep their databases open in WAL mode for the
/// lifetime of the app, and in WAL mode the `.db` file itself barely moves:
/// a whole conversation can land in `-wal` and only reach the database on a
/// checkpoint minutes later. Watching the `.db` alone therefore sees almost
/// nothing, which is why this watches all three files — `.db`, `-wal`, and
/// `-shm` — and treats a change to any of them as a change to the store.
///
/// Two ways to drive it, and a caller normally uses both:
///
/// - **Push.** Call ``check()`` from an ``FSEventsWatcher`` batch that
///   mentioned one of ``watchedPaths``. Sub-second, and free when idle.
/// - **Poll.** ``start()`` runs a timer at `pollInterval`. This is the
///   fallback that matters, because a WAL write is often only an `mmap`
///   store into an already-sized `-shm` file, and FSEvents does not
///   reliably report those at all.
///
/// The watcher itself reads no SQL. It compares `(inode, size, mtime)` and
/// says "something moved"; deciding what moved is the tailer's job.
public final class SQLiteChangeWatcher: Sendable {
    /// One file of the store that changed since the last check.
    public struct Change: Hashable, Sendable {
        /// Which of the three files changed.
        public let path: String
        /// Its size after the change.
        public let size: Int64
        /// Its modification time after the change.
        public let modified: Date

        /// Creates a change record.
        public init(path: String, size: Int64, modified: Date) {
            self.path = path
            self.size = size
            self.modified = modified
        }
    }

    /// The database this watcher is about.
    public let databasePath: String
    /// How often ``start()``'s timer re-checks.
    public let pollInterval: TimeInterval
    /// The database and its WAL/SHM siblings — everything a file-system
    /// watcher should subscribe to for this store.
    public let watchedPaths: [String]

    /// Ticks, one per check that found something. Finished by ``stop()``.
    public let changes: AsyncStream<[Change]>

    private let continuation: AsyncStream<[Change]>.Continuation
    private let stamps: Mutex<[String: FileStamp]>
    private let timerBox: Mutex<DispatchSourceTimer?>
    private let queue: DispatchQueue

    /// Creates a watcher over `databasePath` and its WAL/SHM siblings.
    ///
    /// The first ``check()`` after creation reports every file that exists,
    /// because "not seen before" and "changed" are the same thing to a
    /// cursor that has not read anything yet. Call
    /// ``primeWithCurrentState()`` first to suppress that.
    public init(databasePath: String, pollInterval: TimeInterval = 2) {
        self.databasePath = databasePath
        self.pollInterval = pollInterval
        self.watchedPaths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        self.stamps = Mutex([:])
        self.timerBox = Mutex(nil)
        self.queue = DispatchQueue(label: "com.astroqore.AgentSessionLive.sqlite-watch")
        var escapee: AsyncStream<[Change]>.Continuation!
        self.changes = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escapee = $0 }
        self.continuation = escapee
    }

    deinit {
        timerBox.withLock { $0?.cancel(); $0 = nil }
        continuation.finish()
    }

    /// Records the current state without reporting it, so the next
    /// ``check()`` only reports what happened after this call.
    public func primeWithCurrentState() {
        stamps.withLock { stamps in
            for path in watchedPaths {
                stamps[path] = FileStamp.read(path: path)
            }
        }
    }

    /// Compares the store's files against the last observed state, yields
    /// anything that moved, and returns it.
    ///
    /// A file that disappeared counts as a change — a WAL checkpoint removes
    /// `-wal` and `-shm`, and that is precisely the moment the `.db` grew.
    @discardableResult
    public func check() -> [Change] {
        let found: [Change] = stamps.withLock { stamps in
            var changed: [Change] = []
            for path in watchedPaths {
                let now = FileStamp.read(path: path)
                let before = stamps[path]
                guard now != before else { continue }
                stamps[path] = now
                if let now {
                    changed.append(Change(path: path, size: now.size, modified: now.modified))
                } else {
                    changed.append(Change(path: path, size: 0, modified: Date()))
                }
            }
            return changed
        }
        if !found.isEmpty { continuation.yield(found) }
        return found
    }

    /// Starts the polling timer. Idempotent.
    public func start() {
        timerBox.withLock { box in
            guard box == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + pollInterval,
                repeating: pollInterval,
                leeway: .milliseconds(200)
            )
            timer.setEventHandler { [weak self] in self?.check() }
            box = timer
            timer.resume()
        }
    }

    /// Stops the timer and finishes ``changes``.
    public func stop() {
        timerBox.withLock { $0?.cancel(); $0 = nil }
        continuation.finish()
    }

    /// `true` when `path` is one of the three files this watcher cares
    /// about. Cheap enough to call once per path of an FSEvents batch.
    public func owns(path: String) -> Bool {
        watchedPaths.contains(path)
    }

    /// The database path behind a `.db`, `-wal`, or `-shm` path, or `nil`
    /// when the path is none of those shapes.
    ///
    /// Free function in spirit: an ingest coordinator uses it to map an
    /// FSEvents path back to the store it belongs to without holding a
    /// watcher per database.
    public static func databasePath(forStoreFile path: String) -> String? {
        for suffix in ["-wal", "-shm"] where path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
        let lowered = path.lowercased()
        for suffix in [".db", ".sqlite", ".sqlite3"] where lowered.hasSuffix(suffix) {
            return path
        }
        return nil
    }

    /// `true` when a path looks like a SQLite store or one of its siblings.
    public static func isStoreFile(_ path: String) -> Bool {
        databasePath(forStoreFile: path) != nil
    }
}
