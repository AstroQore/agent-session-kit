import AgentSessionKit
import Foundation
import Synchronization

/// How much file-system work discovery did.
///
/// Discovery is the one part of the live layer whose cost scales with how much
/// history is on the machine rather than with how much is happening now, so
/// "how many directories did that sweep list" is the number that decides
/// whether a board idles at three per cent or at twenty. The counters exist so
/// a test can assert that a second sweep over an unchanged tree is nearly free
/// instead of timing it — a wall-clock assertion on a shared machine measures
/// the machine.
///
/// Internal on purpose: a host has no business branching on these, and they
/// describe an implementation rather than a store.
struct DiscoveryCounters: Hashable, Sendable {
    /// Directory listings — one per `readdir` sweep an adapter asked for.
    var directoryListings = 0
    /// Advisory-lock probes — one `open` + `F_GETLK` + `close` each.
    var lockProbes = 0
    /// Bounded reads of a file's contents: a transcript head, a summary, a
    /// sidecar, a SQLite store opened to answer one question.
    var fileReads = 0

    /// The work done between two snapshots.
    static func - (lhs: Self, rhs: Self) -> Self {
        DiscoveryCounters(
            directoryListings: lhs.directoryListings - rhs.directoryListings,
            lockProbes: lhs.lockProbes - rhs.lockProbes,
            fileReads: lhs.fileReads - rhs.fileReads
        )
    }

    /// Every counter at zero — an unchanged store cost nothing to re-examine.
    var isZero: Bool { directoryListings == 0 && lockProbes == 0 && fileReads == 0 }
}

/// The file-system calls discovery makes, in one place and counted.
///
/// Every adapter used to carry its own private `children(of:)` — five copies
/// of the same "list a directory, refuse a symlink" loop, differing only in
/// which enumeration options they passed. They are one function now, for two
/// reasons: the symlink rule is a security rule and wants a single site, and a
/// counted call is the only honest way to assert that caching works.
enum DiscoveryIO {
    /// Somewhere to count into, installed for the duration of one measured
    /// call. A class because a task-local value has to be copyable and a
    /// `Mutex` is not.
    final class Ledger: Sendable {
        private let counters = Mutex(DiscoveryCounters())

        var counted: DiscoveryCounters { counters.withLock { $0 } }

        fileprivate func add(listings: Int = 0, lockProbes: Int = 0, fileReads: Int = 0) {
            counters.withLock { counters in
                counters.directoryListings += listings
                counters.lockProbes += lockProbes
                counters.fileReads += fileReads
            }
        }
    }

    /// Where to count, when anybody is counting.
    ///
    /// Task-local rather than global, for two reasons. Nothing is counted at
    /// all outside a ``counting(_:)`` call, so the pipeline pays nothing for
    /// a facility only the suite uses; and two tests measuring at once cannot
    /// see each other's syscalls, which a process-wide counter would make
    /// them do the moment the suite runs them in parallel.
    @TaskLocal private static var ledger: Ledger?

    /// Runs `body` and reports the file-system work it did.
    ///
    /// Only work on `body`'s own task is counted — a task-local does not
    /// cross into a `Task.detached`, which is where the coordinator runs
    /// discovery. Measure an adapter directly.
    static func counting<T>(
        _ body: () async throws -> T
    ) async rethrows -> (value: T, cost: DiscoveryCounters) {
        let ledger = Ledger()
        let value = try await $ledger.withValue(ledger) { try await body() }
        return (value, ledger.counted)
    }

    /// Records that something read a file's contents. Called by the adapters
    /// at the points where a cache is meant to be preventing the read.
    static func countFileRead() {
        ledger?.add(fileReads: 1)
    }

    /// Directory entries, never following a symlink.
    ///
    /// A link inside a session store can resolve anywhere, and this package
    /// does not read anywhere. Both `isSymbolicLink` and `isDirectory` are
    /// pre-fetched because every caller asks for at least one of them, and a
    /// key that was not requested costs a `getattrlist` per entry.
    static func children(
        of url: URL,
        options: FileManager.DirectoryEnumerationOptions = [],
        sorted: Bool = true
    ) -> [URL] {
        ledger?.add(listings: 1)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else { return [] }
        let real = entries.filter { (try? $0.resourceValues(forKeys: keys).isSymbolicLink) != true }
        return sorted ? real.sorted { $0.lastPathComponent < $1.lastPathComponent } : real
    }

    /// Entry names, for a caller that only needs the names.
    ///
    /// Cheaper than ``children(of:options:sorted:)`` — no `URL` per entry and
    /// no resource values — and it is what the Claude builders want, since
    /// they decide everything from the file name.
    static func names(in url: URL) -> [String] {
        ledger?.add(listings: 1)
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// Whether `url` is a directory, from the values a listing pre-fetched.
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// ``LockFileProbe/lockState(path:)``, counted.
    static func lockState(path: String) -> LockFileProbe.LockState {
        ledger?.add(lockProbes: 1)
        return LockFileProbe.lockState(path: path)
    }

    /// ``LockFileProbe/isLocked(path:)``, counted.
    static func isLocked(path: String) -> Bool {
        lockState(path: path).isLocked
    }

    /// Whether `path` sits at or below `root`.
    ///
    /// String arithmetic, deliberately: both sides come from the same
    /// vocabulary — ``FSEventsWatcher`` rewrites every delivered path back
    /// under the root the caller declared — so resolving either against the
    /// filesystem would cost a syscall per event and answer the same thing.
    /// A separator is required after the root, or `/a/bc` would count as
    /// living under `/a/b`.
    static func path(_ path: String, isUnder root: String) -> Bool {
        if path == root { return true }
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path.hasPrefix(root + "/")
    }
}
