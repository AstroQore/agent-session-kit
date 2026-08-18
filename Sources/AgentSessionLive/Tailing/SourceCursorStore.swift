import AgentSessionKit
import Foundation

/// Somewhere to keep tailing cursors between runs.
///
/// Relaunching should not mean re-reading every transcript on the machine.
/// A host persists the cursors it got from
/// ``IngestCoordinator/snapshotCursors()`` and hands them back at the next
/// start; sources whose cursor no longer fits — a rotated inode, a row id
/// past the end — re-seed on their own, so a stale store is a slow start
/// rather than a wrong one.
///
/// Keys are ``SessionSource/primaryPath``. Not the ``SessionKey``: a source
/// is discovered by path before anything has read enough of it to be sure of
/// its session id, and resuming has to work on the first poll.
///
/// The package ships two implementations — ``InMemoryCursorStore`` for tests
/// and short-lived hosts, ``JSONFileCursorStore`` for a host with no database
/// of its own. Auspex implements this over GRDB and never uses either.
public protocol SourceCursorStore: Sendable {
    /// Every cursor previously saved, keyed by primary path. A store with
    /// nothing in it returns `[:]` rather than throwing.
    func load() async throws -> [String: SourceCursor]

    /// Replaces the stored set with `cursors`.
    ///
    /// Called every couple of seconds while anything is moving, and once
    /// more on shutdown. An implementation that cannot make that cheap
    /// should coalesce internally; the coordinator will not batch further.
    func save(_ cursors: [String: SourceCursor]) async throws
}

/// A cursor store that keeps everything in memory.
///
/// Useful for a host that re-seeds on every launch by design, and for tests,
/// which is why it counts its saves: asserting that the coordinator actually
/// persisted on shutdown is otherwise untestable.
public actor InMemoryCursorStore: SourceCursorStore {
    /// The current contents.
    public private(set) var cursors: [String: SourceCursor]
    /// How many times ``save(_:)`` has been called.
    public private(set) var saveCount = 0

    /// Creates a store, optionally pre-populated to simulate a previous run.
    public init(_ initial: [String: SourceCursor] = [:]) {
        self.cursors = initial
    }

    public func load() -> [String: SourceCursor] { cursors }

    public func save(_ cursors: [String: SourceCursor]) {
        self.cursors = cursors
        saveCount += 1
    }
}

/// A cursor store backed by one JSON file the caller names.
///
/// Written atomically — a replace of a temporary sibling — because the
/// alternative is a truncated file after a crash, and a truncated cursor
/// file is worse than no cursor file: it makes every source look like it was
/// never read while looking like it was.
///
/// The file is created `0600`. It contains file paths under the user's home,
/// which is not a credential but is not something to leave world-readable
/// either.
///
/// Nothing is invented about the location: the caller passes a `url`, and the
/// only directory this type creates is that file's immediate parent.
public struct JSONFileCursorStore: SourceCursorStore {
    /// The file the cursors live in.
    public let url: URL

    /// Creates a store over `url`. Nothing is read or written until
    /// ``load()`` or ``save(_:)`` is called.
    public init(url: URL) {
        self.url = url
    }

    /// Reads the file, or returns `[:]` when it is absent.
    ///
    /// A file that exists but does not decode also yields `[:]`, with a
    /// warning: a host that changed its cursor representation should
    /// re-seed, not fail to start.
    public func load() throws -> [String: SourceCursor] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([String: SourceCursor].self, from: data)
        } catch {
            KitLog.warn("JSONFileCursorStore: unreadable cursor file, starting cold")
            return [:]
        }
    }

    /// Writes `cursors`, replacing whatever was there.
    public func save(_ cursors: [String: SourceCursor]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cursors)

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
