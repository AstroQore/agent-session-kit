import Foundation
import SQLite3

/// Read helpers for another app's SQLite store while that app is running.
///
/// AntiGravity's conversation databases, Cursor's agent stores, and Devin's
/// shared session database are all written by processes that may be running
/// right now, so they routinely carry a live `-wal` / `-shm` pair. That rules
/// out `immutable=1` while a journal exists — the flag tells SQLite there is
/// no journal to replay, which on a live database means reading a stale or
/// torn snapshot.
///
/// The strategy is therefore: open the real file read-only with a short busy
/// timeout and, only if that fails to produce a complete read, snapshot the
/// file (plus its journal siblings) into a private temp directory and read the
/// copy. The copy is deleted before returning. Nothing here ever opens the
/// original for writing.
/// Public because `AgentSessionLive` tails the same two stores. A live tailer
/// that reimplemented the open flags, the busy timeout, and the snapshot
/// fallback would be a second copy of the one piece of this package where
/// getting it wrong corrupts somebody else's database.
public enum LiveSQLiteReader {
    /// Why a read gave up. Never produced for a missing row — only for a
    /// statement the database refused to prepare or step.
    public enum ReadError: Error {
        /// A statement could not be prepared, or stepping it failed with
        /// something other than "no more rows".
        case statement
    }

    /// Maximum rows any single query here will materialize. A conversation
    /// with more rows than this is pathological; truncating keeps a session
    /// list from allocating without bound.
    public static let maxRows = 5_000
    /// Individual payload blobs are a few KB; anything past this is not a
    /// transcript and is skipped rather than copied into memory.
    public static let maxBlobBytes = 4 * 1024 * 1024

    /// Run `body` against a read-only handle on `url`, falling back to a
    /// snapshot copy. Returns `nil` when neither route produced a result;
    /// `body` must build its output from scratch so a retry is clean.
    ///
    /// `snapshotFallback: false` gives up after the direct read instead. That
    /// is for a probe run once per session against a store many sessions
    /// share (Devin's), where one locked moment must not turn into a copy of
    /// the whole database per session: the caller skips and asks again later.
    public static func read<T>(
        at url: URL,
        snapshotFallback: Bool = true,
        _ body: (OpaquePointer) throws -> T
    ) -> T? {
        if let handle = open(path: url.path) {
            defer { sqlite3_close_v2(handle) }
            if let value = try? body(handle) { return value }
        }
        // A WAL database whose last writer closed cleanly has no `-wal` left,
        // and a read-only connection cannot create one, so the plain open
        // above fails with SQLITE_CANTOPEN. Nothing is waiting to be replayed
        // in that state, and a writer that arrives mid-read appends to a new
        // journal rather than touching the main file, so the file is read in
        // place rather than copied.
        if isCheckpointedWALDatabase(url),
           let handle = open(path: immutableURI(url.path), uri: true) {
            defer { sqlite3_close_v2(handle) }
            if let value = try? body(handle) { return value }
        }
        guard snapshotFallback, let snapshot = snapshot(of: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

        // The copy is ours, so a read-write open is allowed to replay the
        // copied WAL. `immutable=1` is the last resort, for a copy whose
        // journal siblings were not readable either.
        if let handle = open(path: snapshot.path, readOnly: false) {
            defer { sqlite3_close_v2(handle) }
            if let value = try? body(handle) { return value }
        }
        guard let handle = open(path: immutableURI(snapshot.path), uri: true) else {
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        return try? body(handle)
    }

    /// The file's header says WAL (format bytes 18 and 19 are both 2) and no
    /// `-wal` sibling exists.
    static func isCheckpointedWALDatabase(_ url: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path + "-wal"),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[header.startIndex + 18] == 2 && header[header.startIndex + 19] == 2
    }

    /// `file:<path>?immutable=1`, with the path percent-encoded the way a
    /// SQLite URI requires (`?`, `#`, and `%` would otherwise end or escape it).
    static func immutableURI(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(encoded)?immutable=1"
    }

    private static func open(path: String, readOnly: Bool = true, uri: Bool = false) -> OpaquePointer? {
        var handle: OpaquePointer?
        var flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        if uri { flags |= SQLITE_OPEN_URI }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close_v2(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 250)
        return handle
    }

    /// Copy `url` and its `-wal` / `-shm` siblings into a fresh temp
    /// directory. The directory (not just the file) is unique so a
    /// concurrent refresh can never collide, and the caller removes it.
    private static func snapshot(of url: URL) -> URL? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("AgentSessionKitSQLiteSnapshot-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let target = directory.appendingPathComponent(url.lastPathComponent)
        guard (try? fm.copyItem(at: url, to: target)) != nil else {
            try? fm.removeItem(at: directory)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let sibling = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix)
            guard fm.fileExists(atPath: sibling.path) else { continue }
            try? fm.copyItem(
                at: sibling,
                to: directory.appendingPathComponent(target.lastPathComponent + suffix)
            )
        }
        return target
    }

    // MARK: - Statements

    /// Compiles `sql` against `database`, throwing rather than returning a
    /// half-built statement. The caller owns the result and must finalize it.
    public static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if statement != nil { sqlite3_finalize(statement) }
            throw ReadError.statement
        }
        return statement
    }

    /// One BLOB column, or `nil` when it is empty, NULL, or larger than
    /// ``maxBlobBytes``.
    public static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let raw = sqlite3_column_blob(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, length <= maxBlobBytes else { return nil }
        return Data(bytes: raw, count: length)
    }

    /// One TEXT column as a Swift string, or `nil` when it is NULL.
    public static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
