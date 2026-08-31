import Foundation
import Synchronization

/// Something an adapter derived from a file, kept until that file changes.
///
/// Discovery re-examines every recent session on every pass, and most of what
/// it reads is immutable: a transcript's header, a subagent's `meta.json`, the
/// `summary.json` a harness rewrote an hour ago. Decoding those again on every
/// pass is what turns a sweep over a machine with hundreds of sessions into a
/// hot loop, and it is pure waste — the answer cannot have changed.
///
/// The version is whatever fact about the file makes the derived value stale.
/// For a header it is the **inode**: the head of an append-only transcript
/// never changes, and a file with a new inode is a different file. For a
/// document a harness rewrites in place it is the whole ``FileStamp``, so a
/// rewrite of the same size at the same second still invalidates through the
/// mtime's nanoseconds. Passing a version that is too weak keeps a stale
/// answer; passing one that is too strong only costs the read this exists to
/// avoid, so when in doubt pass the stamp.
///
/// A class so the value-typed adapters can share one across their copies, and
/// a `Mutex` because discovery runs off the coordinator's actor.
final class DiscoveryCache<Version: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let version: Version
        let value: Value
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let limit: Int

    /// Creates a cache.
    ///
    /// - Parameter limit: How many entries to keep before dropping all of
    ///   them. Bounded rather than evicted by age: a machine with a year of
    ///   sessions should not keep a year of derived values, and the sessions
    ///   discovery actually revisits are re-derived once per eviction.
    init(limit: Int = 1024) {
        self.limit = limit
    }

    /// The cached value for `path`, or `build()`'s, remembered under
    /// `version`.
    ///
    /// `build` runs outside the lock. Two threads racing on the same path
    /// therefore both build, which is a wasted read and never a wrong answer;
    /// holding the lock across a file read would serialise every adapter
    /// behind the slowest one.
    func value(
        path: String,
        version: Version,
        build: () -> Value
    ) -> Value {
        let hit = entries.withLock { map -> Value? in
            guard let entry = map[path], entry.version == version else { return nil }
            return entry.value
        }
        if let hit { return hit }

        let value = build()
        entries.withLock { map in
            if map.count >= limit { map.removeAll(keepingCapacity: true) }
            map[path] = Entry(version: version, value: value)
        }
        return value
    }

    /// Forgets everything. Tests only.
    func clear() {
        entries.withLock { $0.removeAll() }
    }

    /// How many entries are held. Tests only.
    var count: Int { entries.withLock(\.count) }
}

/// The version to cache under for a file that may not exist.
///
/// A missing file is a fact worth caching too — `summary.json` is absent for
/// every session a harness has not written one for, and re-discovering that
/// with an `open` per pass is the same waste as re-parsing one. The sentinel
/// is distinct from any real stamp (no file has inode zero), so the entry
/// invalidates the moment the file appears.
extension FileStamp {
    /// A stamp that stands for "this file was not there".
    static let missing = FileStamp(inode: 0, size: -1, modified: .distantPast)

    /// The stamp of `path`, or ``missing``.
    static func version(ofPath path: String) -> FileStamp {
        read(path: path) ?? .missing
    }
}
