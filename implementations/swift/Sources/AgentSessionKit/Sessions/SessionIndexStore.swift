import Darwin
import Foundation
import SQLite3

public enum SessionIndexError: Error, Sendable {
    /// The SQLite file could not be opened or migrated.
    case open
    /// A statement failed to prepare, bind, or step.
    case statement
}

/// One search result: the session that matched, plus where in it.
public struct SessionSearchHit: Hashable, Sendable {
    public let summary: SessionSummary
    /// FTS5 snippet with `<b>` markers around the match, or nil when the
    /// hit came from the session's own metadata rather than its body.
    public let snippet: String?
    /// Position of the matching message inside the transcript, so a UI
    /// can open the transcript scrolled to it.
    public let matchedSeq: Int?

    public init(summary: SessionSummary, snippet: String?, matchedSeq: Int?) {
        self.summary = summary
        self.snippet = snippet
        self.matchedSeq = matchedSeq
    }
}

/// Persistent index over every discovered session.
///
/// Three tables and a virtual one:
///
/// - `sessions` — one row per discovered session, keyed by
///   `(provider, session_id, source_path)` because the same id can
///   legitimately appear under two roots;
/// - `session_files` — the incremental-scan cursor: a hashed path, the
///   fingerprint last indexed at, and the session it produced;
/// - `session_messages` — per-message excerpts, only written when body
///   indexing is enabled;
/// - `session_fts` — an external-content FTS5 table over those excerpts,
///   kept in sync by triggers.
///
/// The tokenizer is `trigram`, not the default unicode61: it is the only
/// built-in tokenizer that matches *inside* words, which is what makes
/// substring search work for CJK text (no word spacing) and for
/// identifiers alike. Its cost is that queries shorter than three
/// characters cannot be answered at all — `search` falls back to `LIKE`
/// for those.
///
/// Everything here is reconstructible from the CLIs' own session logs, so
/// a schema-version mismatch drops and rebuilds instead of migrating.
public actor SessionIndexStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Bumping this drops and rebuilds every table on the next open.
    ///
    /// v2 added `sessions.harness` and `sessions.model`. There is no ALTER
    /// path on purpose: every row is reconstructible from the CLIs' own
    /// logs, and a rebuild is what fills the new columns anyway.
    ///
    /// v3 changes no columns; it forces a re-index because Claude Code rows
    /// carried the inherited per-line `sessionId` of forked / continued
    /// sessions instead of the file's own UUID, and a fingerprint-driven
    /// incremental pass would never revisit those unchanged files.
    ///
    /// v4 also changes no columns; it backfills system and tool excerpts now
    /// that callers can choose the message roles a search is allowed to hit.
    ///
    /// v5 rebuilds the same logical index through bounded bulk transactions.
    /// The body/search result set is unchanged; only the construction path is
    /// different, so an interrupted v4 rebuild cannot keep its pathological
    /// one-session-per-FTS-transaction layout.
    static let schemaVersion = 5

    /// Open (or create) the index at `url`.
    ///
    /// There is deliberately **no default location**. The index is derived
    /// data about the caller's user, and a library that picks its own path
    /// under `~/` is a library that writes somewhere its host never agreed
    /// to. The caller names the file; `createDirectory` creates that file's
    /// own parent (0700) as a convenience, and nothing above it.
    public init(url: URL, createDirectory: Bool = true) throws {
        if createDirectory {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            throw SessionIndexError.open
        }
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.initialize(handle)
            database = handle
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Schema

    private static func initialize(_ database: OpaquePointer) throws {
        let preamble = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA foreign_keys=ON;
            PRAGMA temp_store=FILE;
            PRAGMA cache_size=-32768;
            """
        guard sqlite3_exec(database, preamble, nil, nil, nil) == SQLITE_OK else {
            throw SessionIndexError.open
        }
        if storedSchemaVersion(database) != schemaVersion {
            guard sqlite3_exec(database, dropSQL, nil, nil, nil) == SQLITE_OK else {
                throw SessionIndexError.open
            }
        }
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA user_version = \(schemaVersion)", nil, nil, nil) == SQLITE_OK
        else {
            throw SessionIndexError.open
        }
    }

    private static func storedSchemaVersion(_ database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Triggers first, then the virtual table, then the content tables —
    /// dropping an external-content FTS5 table after its content table is
    /// gone still works, but the order keeps the intent readable.
    private static let dropSQL = """
        DROP TRIGGER IF EXISTS session_messages_ai;
        DROP TRIGGER IF EXISTS session_messages_ad;
        DROP TABLE IF EXISTS session_fts;
        DROP TABLE IF EXISTS session_messages;
        DROP TABLE IF EXISTS session_files;
        DROP TABLE IF EXISTS sessions;
        DROP TABLE IF EXISTS session_index_meta;
        """

    /// Exposed for `SessionIndexContractTests`, which compares the objects
    /// created here against `contracts/storage/session-index-v5.sql`.
    static var schemaSQLForContractTests: String { schemaSQL }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS session_index_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            provider_variant TEXT,
            harness TEXT,
            model TEXT,
            title TEXT,
            summary TEXT,
            project_dir TEXT,
            created_at INTEGER,
            last_active_at INTEGER,
            source_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT -1,
            UNIQUE(provider, session_id, source_path)
        );
        CREATE INDEX IF NOT EXISTS sessions_last_active_idx
            ON sessions(last_active_at DESC);
        CREATE INDEX IF NOT EXISTS sessions_effective_active_idx
            ON sessions(COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE INDEX IF NOT EXISTS sessions_provider_effective_active_idx
            ON sessions(provider, COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE INDEX IF NOT EXISTS sessions_provider_project_idx
            ON sessions(provider, project_dir);
        CREATE INDEX IF NOT EXISTS sessions_harness_effective_active_idx
            ON sessions(harness, COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE TABLE IF NOT EXISTS session_files (
            path_hash TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            provider TEXT NOT NULL,
            mtime_ns INTEGER NOT NULL,
            size INTEGER NOT NULL,
            session_row INTEGER REFERENCES sessions(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS session_messages (
            id INTEGER PRIMARY KEY,
            session_row INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            excerpt TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS session_messages_row_idx
            ON session_messages(session_row, seq);
        CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
            excerpt,
            content='session_messages',
            content_rowid='id',
            tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS session_messages_ai
        AFTER INSERT ON session_messages BEGIN
            INSERT INTO session_fts(rowid, excerpt) VALUES (new.id, new.excerpt);
        END;
        CREATE TRIGGER IF NOT EXISTS session_messages_ad
        AFTER DELETE ON session_messages BEGIN
            INSERT INTO session_fts(session_fts, rowid, excerpt)
                VALUES('delete', old.id, old.excerpt);
        END;
        """

    // MARK: - Writes

    /// Insert or refresh one session, returning its row id.
    ///
    /// The harness column is never left null: a summary that arrived without
    /// one is stored under `provider.defaultHarness`, so the harness filter
    /// below is total and no row can hide from every chip.
    @discardableResult
    public func upsertSession(_ summary: SessionSummary) throws -> Int64 {
        try run(
            """
            INSERT INTO sessions(
                   provider, session_id, provider_variant, harness, model,
                   title, summary, project_dir,
                   created_at, last_active_at, source_path, size_bytes, message_count
               ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(provider, session_id, source_path) DO UPDATE SET
                   provider_variant = excluded.provider_variant,
                   harness = excluded.harness,
                   model = excluded.model,
                   title = excluded.title,
                   summary = excluded.summary,
                   project_dir = excluded.project_dir,
                   created_at = excluded.created_at,
                   last_active_at = excluded.last_active_at,
                   size_bytes = excluded.size_bytes,
                   message_count = excluded.message_count
            """,
            [
                .text(summary.provider.rawValue),
                .text(summary.sessionID),
                summary.providerVariant.map(Binding.text) ?? .null,
                .text(summary.effectiveHarness.rawValue),
                summary.model.map(Binding.text) ?? .null,
                summary.title.map(Binding.text) ?? .null,
                summary.summary.map(Binding.text) ?? .null,
                summary.projectDir.map(Binding.text) ?? .null,
                summary.createdAt.map { .integer(Self.epoch($0)) } ?? .null,
                summary.lastActiveAt.map { .integer(Self.epoch($0)) } ?? .null,
                .text(summary.sourcePath),
                .integer(summary.sizeBytes),
                .integer(Int64(summary.messageCount))
            ]
        )
        guard let row = try sessionRowID(summary, path: summary.sourcePath) else {
            throw SessionIndexError.statement
        }
        return row
    }

    private func sessionRowID(_ summary: SessionSummary, path: String) throws -> Int64? {
        try scalarInt(
            "SELECT id FROM sessions WHERE provider = ? AND session_id = ? AND source_path = ?",
            [.text(summary.provider.rawValue), .text(summary.sessionID), .text(path)]
        )
    }

    public struct MessageExcerpt: Hashable, Sendable {
        public let seq: Int
        public let role: SessionRole
        public let excerpt: String

        public init(seq: Int, role: SessionRole, excerpt: String) {
            self.seq = seq
            self.role = role
            self.excerpt = excerpt
        }
    }

    public struct IndexBatchEntry: Sendable {
        public let summary: SessionSummary
        public let pathHash: String
        public let path: String
        public let provider: SessionProvider
        public let mtimeNanos: Int64
        public let size: Int64
        /// `nil` means metadata-only indexing. An empty array deliberately
        /// clears a session whose readable transcript became empty.
        public let excerpts: [MessageExcerpt]?
        var requiresFullRefresh = false
        var clearsPartial = false

        public init(
            summary: SessionSummary,
            pathHash: String,
            path: String,
            provider: SessionProvider,
            mtimeNanos: Int64,
            size: Int64,
            excerpts: [MessageExcerpt]?
        ) {
            self.summary = summary
            self.pathHash = pathHash
            self.path = path
            self.provider = provider
            self.mtimeNanos = mtimeNanos
            self.size = size
            self.excerpts = excerpts
        }
    }

    /// Commits a bounded group of sessions as one FTS transaction. Building a
    /// large index one session per transaction creates thousands of tiny FTS5
    /// segments and repeatedly merges them; batching keeps both segment count
    /// and merge working sets bounded without dropping a single excerpt.
    public func applyIndexBatch(_ entries: [IndexBatchEntry]) throws {
        guard !entries.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for entry in entries {
                let row = try upsertIndexEntry(entry)
                if let excerpts = entry.excerpts {
                    try replaceMessagesUncommitted(sessionRow: row, excerpts: excerpts)
                }
                try saveFileCursor(
                    pathHash: entry.pathHash,
                    path: entry.path,
                    provider: entry.provider,
                    mtimeNanos: entry.mtimeNanos,
                    size: entry.size,
                    sessionRow: row
                )
                if entry.requiresFullRefresh {
                    try run("INSERT OR IGNORE INTO session_index_meta(key, value) VALUES(?, '1')",
                            [.text(Self.partialPrefix + entry.pathHash)])
                } else if entry.clearsPartial {
                    try removePartialMarker(pathHash: entry.pathHash)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func upsertIndexEntry(_ entry: IndexBatchEntry) throws -> Int64 {
        let summary = entry.summary
        guard entry.requiresFullRefresh, entry.provider == .codex,
              CodexRolloutFile.isCompressed(URL(fileURLWithPath: entry.path)) else {
            return try upsertSession(summary)
        }

        // A bounded archive read cannot see the activity tail. Preserve
        // authoritative cached metadata, and on a real plain → zstd rename
        // move the existing session row instead of showing two histories.
        if let row = try sessionRowID(summary, path: summary.sourcePath) {
            try run("UPDATE sessions SET size_bytes = ? WHERE id = ?", [.integer(summary.sizeBytes), .integer(row)])
            return row
        }
        let plain = CodexRolloutFile.canonicalPath(summary.sourcePath)
        if Self.missingFile(at: plain), let row = try sessionRowID(summary, path: plain) {
            try run("UPDATE sessions SET source_path = ?, size_bytes = ? WHERE id = ?",
                    [.text(summary.sourcePath), .integer(summary.sizeBytes), .integer(row)])
            try run("DELETE FROM session_files WHERE path = ?", [.text(plain)])
            try removePartialMarker(pathHash: SessionIndexService.pathHash(plain))
            return row
        }
        return try upsertSession(summary)
    }

    /// Replace every indexed excerpt for one session. The delete trigger
    /// clears the old FTS rows, so this is also how a shrinking
    /// transcript stops matching its removed text.
    public func replaceMessages(sessionRow: Int64, excerpts: [MessageExcerpt]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try replaceMessagesUncommitted(sessionRow: sessionRow, excerpts: excerpts)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func replaceMessagesUncommitted(
        sessionRow: Int64,
        excerpts: [MessageExcerpt]
    ) throws {
        try run("DELETE FROM session_messages WHERE session_row = ?", [.integer(sessionRow)])
        guard !excerpts.isEmpty else { return }
        let statement = try prepare(
            "INSERT INTO session_messages(session_row, seq, role, excerpt) VALUES(?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        for excerpt in excerpts {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindAll([
                .integer(sessionRow),
                .integer(Int64(excerpt.seq)),
                .text(excerpt.role.rawValue),
                .text(excerpt.excerpt)
            ], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionIndexError.statement
            }
        }
    }

    /// Asks SQLite to release connection-local caches after each bulk batch.
    /// The host additionally applies malloc-zone pressure relief, so neither
    /// layer retains a rebuild-sized high-water mark.
    public func releaseTransientMemory() {
        guard let database else { return }
        _ = sqlite3_db_release_memory(database)
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        _ = sqlite3_wal_checkpoint_v2(
            database, nil, SQLITE_CHECKPOINT_PASSIVE,
            &logFrames, &checkpointedFrames
        )
    }

    /// Fingerprint of a file as of its last successful index pass.
    public struct FileCursor: Hashable, Sendable {
        public let mtimeNanos: Int64
        public let size: Int64
        public let sessionRow: Int64?
        let requiresFullRefresh: Bool

        public init(mtimeNanos: Int64, size: Int64, sessionRow: Int64?) {
            self.init(mtimeNanos: mtimeNanos, size: size, sessionRow: sessionRow, requiresFullRefresh: false)
        }

        init(mtimeNanos: Int64, size: Int64, sessionRow: Int64?, requiresFullRefresh: Bool) {
            self.mtimeNanos = mtimeNanos
            self.size = size
            self.sessionRow = sessionRow
            self.requiresFullRefresh = requiresFullRefresh
        }
    }

    private static let partialPrefix = "partial_metadata:"

    private func removePartialMarker(pathHash: String) throws {
        try run("DELETE FROM session_index_meta WHERE key = ?", [.text(Self.partialPrefix + pathHash)])
    }

    public func fileCursor(pathHash: String) throws -> FileCursor? {
        try fileCursors(pathHashes: [pathHash])[pathHash]
    }

    /// One lookup per index chunk. The indexer caps chunks below SQLite's
    /// parameter limit, so each statement has a small and bounded result.
    func fileCursors(pathHashes: [String]) throws -> [String: FileCursor] {
        guard !pathHashes.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: pathHashes.count).joined(separator: ",")
        let statement = try prepare(
            """
            SELECT f.path_hash, f.mtime_ns, f.size, f.session_row, m.key IS NOT NULL
              FROM session_files f
              LEFT JOIN session_index_meta m ON m.key = '\(Self.partialPrefix)' || f.path_hash
             WHERE f.path_hash IN (\(placeholders))
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(pathHashes.map(Binding.text), to: statement)
        var cursors: [String: FileCursor] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let hash = columnText(statement, 0) {
                cursors[hash] = FileCursor(
                    mtimeNanos: sqlite3_column_int64(statement, 1),
                    size: sqlite3_column_int64(statement, 2),
                    sessionRow: sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(statement, 3),
                    requiresFullRefresh: sqlite3_column_int(statement, 4) != 0
                )
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw SessionIndexError.statement }
        return cursors
    }

    public func saveFileCursor(
        pathHash: String,
        path: String,
        provider: SessionProvider,
        mtimeNanos: Int64,
        size: Int64,
        sessionRow: Int64?
    ) throws {
        try run(
            """
            INSERT INTO session_files(path_hash, path, provider, mtime_ns, size, session_row)
               VALUES(?, ?, ?, ?, ?, ?)
               ON CONFLICT(path_hash) DO UPDATE SET
                   path = excluded.path,
                   provider = excluded.provider,
                   mtime_ns = excluded.mtime_ns,
                   size = excluded.size,
                   session_row = excluded.session_row
            """,
            [
                .text(pathHash), .text(path), .text(provider.rawValue),
                .integer(mtimeNanos), .integer(size),
                sessionRow.map(Binding.integer) ?? .null
            ]
        )
    }

    /// Forget the sessions that came from these paths, and the cursors
    /// pointing at them.
    public func removeSessions(sourcePathIn paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for path in paths {
                try run("DELETE FROM sessions WHERE source_path = ?", [.text(path)])
                try run("DELETE FROM session_files WHERE path = ?", [.text(path)])
                try removePartialMarker(pathHash: SessionIndexService.pathHash(path))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private struct StaleFile: Sendable {
        let hash: String
        let cursor: FileCursor
        let path: String
        let provider: SessionProvider?
    }

    /// Drop every file whose hash is no longer on disk, together with the
    /// session it produced. Returns how many files were pruned.
    @discardableResult
    public func pruneMissing(existingPathHashes: Set<String>) throws -> Int {
        try prune(staleFiles(excluding: existingPathHashes))
    }

    /// Discovery APIs can return a partial list when a store is unreadable.
    /// Independently confirm absence before deleting any undiscovered row.
    func pruneConfirmedMissing(
        existingPathHashes: Set<String>,
        providers: Set<SessionProvider>
    ) async throws -> Int {
        let candidates = try staleFiles(excluding: existingPathHashes).filter {
            $0.provider.map(providers.contains) == true
        }
        guard !candidates.isEmpty else { return 0 }
        let verification = Task.detached(priority: Task.currentPriority) {
            Self.confirmMissing(candidates)
        }
        let confirmed = await withTaskCancellationHandler {
            await verification.value
        } onCancel: {
            verification.cancel()
        }
        try Task.checkCancellation()
        let deletable = try confirmed.filter { file in
            guard file.provider == .codex, file.path.hasSuffix(".jsonl") else { return true }
            let alternate = file.path + ".zst"
            let hash = SessionIndexService.pathHash(alternate)
            guard existingPathHashes.contains(hash) || !Self.missingFile(at: alternate) else { return true }
            // The original disappeared as Codex archived it. Keep the
            // existing index until the replacement has a usable row.
            return try fileCursor(pathHash: hash)?.sessionRow != nil
        }
        return try prune(deletable, checkingCursors: true)
    }

    private func staleFiles(excluding seen: Set<String>) throws -> [StaleFile] {
        var stale: [StaleFile] = []
        let statement = try prepare(
            "SELECT path_hash, session_row, path, provider, mtime_ns, size FROM session_files"
        )
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let hash = columnText(statement, 0), !seen.contains(hash),
               let path = columnText(statement, 2) {
                stale.append(StaleFile(
                    hash: hash,
                    cursor: FileCursor(
                        mtimeNanos: sqlite3_column_int64(statement, 4),
                        size: sqlite3_column_int64(statement, 5),
                        sessionRow: sqlite3_column_type(statement, 1) == SQLITE_NULL
                            ? nil : sqlite3_column_int64(statement, 1)
                    ),
                    path: path,
                    provider: columnText(statement, 3).flatMap(SessionProvider.init(rawValue:))
                ))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw SessionIndexError.statement }
        return stale
    }

    private static func confirmMissing(_ candidates: [StaleFile]) -> [StaleFile] {
        var confirmed: [StaleFile] = []
        var databaseRows: [URL: [(file: StaleFile, id: String)]] = [:]
        for file in candidates {
            guard !Task.isCancelled else { return [] }
            if file.provider == .devin {
                if let locator = DevinSessionAdapter.locate(URL(fileURLWithPath: file.path)) {
                    databaseRows[locator.database, default: []].append((file, locator.sessionID))
                }
            } else if missingFile(at: file.path) {
                confirmed.append(file)
            }
        }
        for (database, rows) in databaseRows {
            guard !Task.isCancelled else { return [] }
            if missingFile(at: database.path) {
                confirmed.append(contentsOf: rows.map(\.file))
            } else if DevinSessionAdapter.isRegularFile(database),
                      let missing = LiveSQLiteReader.read(at: database, snapshotFallback: false, { handle in
                          try rows.compactMap { row in
                              try Task.checkCancellation()
                              let session = try DevinSessionAdapter.sessionRow(handle, sessionID: row.id)
                              return session?.isHidden == false ? nil : row.file
                          }
                      }) {
                confirmed.append(contentsOf: missing)
            }
        }
        return confirmed
    }

    private static func missingFile(at path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    private func prune(_ stale: [StaleFile], checkingCursors: Bool = false) throws -> Int {
        guard !stale.isEmpty else { return 0 }
        var count = 0
        try execute("BEGIN IMMEDIATE")
        do {
            for entry in stale {
                // Confirmation waits off-actor. Keep entries rewritten by
                // another store caller while that verification was in flight.
                if checkingCursors {
                    guard let current = try fileCursor(pathHash: entry.hash),
                          current.mtimeNanos == entry.cursor.mtimeNanos,
                          current.size == entry.cursor.size,
                          current.sessionRow == entry.cursor.sessionRow else { continue }
                }
                if let row = entry.cursor.sessionRow {
                    // Cascades through session_messages (and its FTS
                    // trigger) and through session_files.
                    try run("DELETE FROM sessions WHERE id = ?", [.integer(row)])
                }
                try run("DELETE FROM session_files WHERE path_hash = ?", [.text(entry.hash)])
                try removePartialMarker(pathHash: entry.hash)
                count += 1
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return count
    }

    /// Drop every indexed excerpt, keeping the session rows. This is what
    /// switching body indexing off means: metadata search still works,
    /// nothing of the transcripts is left on disk.
    public func dropBodyIndex() throws {
        try run("DELETE FROM session_messages", [])
    }

    /// Forget every scan cursor, so the next refresh re-reads all files.
    /// Session rows survive — they are re-upserted in place, which keeps
    /// row ids (and any UI selection keyed on them) stable.
    public func resetFileCursors() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM session_files", [])
            try run("DELETE FROM session_index_meta WHERE key GLOB ?", [.text(Self.partialPrefix + "*")])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static let bodyIndexingKey = "body_indexing"

    /// Whether the last completed refresh indexed message bodies. `nil`
    /// before the first refresh. Turning the setting back on has to
    /// re-read files whose fingerprint never moved, and this is how that
    /// transition is noticed.
    public func bodyIndexingMode() throws -> Bool? {
        let statement = try prepare("SELECT value FROM session_index_meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bindAll([.text(Self.bodyIndexingKey)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SessionIndexError.statement }
        return columnText(statement, 0) == "1"
    }

    /// Apply a mode transition atomically. Re-enabling body indexing marks
    /// cursors stale but preserves their row mapping so a vanished source can
    /// still be reconciled. The steady state performs no writes.
    @discardableResult
    public func applyBodyIndexingMode(_ enabled: Bool) throws -> Bool {
        guard try bodyIndexingMode() != enabled else { return false }
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            if enabled {
                try run(
                    "UPDATE session_files SET mtime_ns = ?, size = ?",
                    [.integer(.min), .integer(.min)]
                )
            } else {
                try dropBodyIndex()
            }
            try setBodyIndexingMode(enabled)
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func setBodyIndexingMode(_ enabled: Bool) throws {
        try run(
            """
            INSERT INTO session_index_meta(key, value) VALUES(?, ?)
               ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(Self.bodyIndexingKey), .text(enabled ? "1" : "0")]
        )
    }

    /// Wipe every row. The schema stays, so the next refresh rebuilds the
    /// index without reopening the database.
    public func eraseAll() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM session_messages")
            try execute("DELETE FROM session_files")
            try execute("DELETE FROM sessions")
            try execute("DELETE FROM session_index_meta")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reads

    /// Fixed order, and new columns go on the end: the search queries select
    /// `s.id` and the match columns straight after this list, and address
    /// them by index.
    private static let sessionColumns = """
        s.provider, s.session_id, s.provider_variant, s.title, s.summary, s.project_dir,
        s.created_at, s.last_active_at, s.source_path, s.size_bytes, s.message_count,
        s.harness, s.model
        """
    /// Column index of `s.id` in a `SELECT sessionColumns, s.id, …`.
    private static let rowIDColumn: Int32 = 13

    /// Every indexed session, most recently active first.
    public func allSummaries() throws -> [SessionSummary] {
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns) FROM sessions s
             ORDER BY s.last_active_at IS NULL, s.last_active_at DESC, s.id DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        var out: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = self.summary(statement, offset: 0) { out.append(summary) }
        }
        return out
    }

    /// One filtered, ordered page. This is the product read path; the unbounded
    /// `allSummaries()` remains for tests and maintenance tools.
    public func summaryPage(
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        since: Date? = nil,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        excludingProviderVariantPrefix: String? = nil,
        order: SessionSummaryOrder = .recentFirst,
        offset: Int = 0,
        limit: Int = 250
    ) throws -> SessionSummaryPage {
        if let providers, providers.isEmpty {
            return SessionSummaryPage(summaries: [], totalCount: 0, offset: 0, limit: max(1, limit))
        }
        if let harnesses, harnesses.isEmpty {
            return SessionSummaryPage(summaries: [], totalCount: 0, offset: 0, limit: max(1, limit))
        }
        let safeOffset = max(0, offset)
        let safeLimit = min(max(1, limit), 500)
        var clauses: [String] = []
        var bindings: [Binding] = []
        if let providers {
            clauses.append("s.provider IN (\(Array(repeating: "?", count: providers.count).joined(separator: ", ")))")
            bindings.append(contentsOf: providers.map { .text($0.rawValue) })
        }
        if let harnesses {
            clauses.append("s.harness IN (\(Array(repeating: "?", count: harnesses.count).joined(separator: ", ")))")
            bindings.append(contentsOf: harnesses.map { .text($0.rawValue) })
        }
        if let since {
            clauses.append("COALESCE(s.last_active_at, s.created_at) >= ?")
            bindings.append(.integer(Int64(since.timeIntervalSince1970.rounded(.down))))
        }
        Self.appendProjectClauses(
            includes: projectIncludes,
            excludes: projectExcludes,
            clauses: &clauses,
            bindings: &bindings
        )
        if let prefix = SessionParsing.string(excludingProviderVariantPrefix) {
            clauses.append("(s.provider_variant IS NULL OR s.provider_variant NOT LIKE ? ESCAPE '\\')")
            bindings.append(.text(Self.likePattern(prefix) + "%"))
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let orderSQL: String
        switch order {
        case .recentFirst:
            orderSQL = "COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC"
        case .oldestFirst:
            orderSQL = "COALESCE(s.last_active_at, s.created_at) ASC, s.id ASC"
        case .byProject:
            orderSQL = "s.project_dir IS NULL, s.project_dir COLLATE NOCASE ASC, "
                + "COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC"
        }

        let total = Int(try scalarInt(
            "SELECT COUNT(*) FROM sessions s\(whereSQL)",
            bindings
        ) ?? 0)
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns) FROM sessions s\(whereSQL)
             ORDER BY \(orderSQL) LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(bindings + [.integer(Int64(safeLimit)), .integer(Int64(safeOffset))], to: statement)
        var out: [SessionSummary] = []
        out.reserveCapacity(min(safeLimit, total))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = self.summary(statement, offset: 0) { out.append(summary) }
        }
        return SessionSummaryPage(
            summaries: out,
            totalCount: total,
            offset: safeOffset,
            limit: safeLimit
        )
    }

    public func providerCounts() throws -> [SessionProvider: Int] {
        let statement = try prepare("SELECT provider, COUNT(*) FROM sessions GROUP BY provider")
        defer { sqlite3_finalize(statement) }
        var counts: [SessionProvider: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnText(statement, 0), let provider = SessionProvider(rawValue: raw) else {
                continue
            }
            counts[provider] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    /// Row count per harness — what the Sessions page's company chips and
    /// source menu label themselves with. Rows written before the harness
    /// column existed cannot occur (the schema bump rebuilds), so a row that
    /// somehow has no harness is skipped rather than invented.
    public func harnessCounts() throws -> [Harness: Int] {
        let statement = try prepare(
            "SELECT harness, COUNT(*) FROM sessions WHERE harness IS NOT NULL GROUP BY harness"
        )
        defer { sqlite3_finalize(statement) }
        var counts: [Harness: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnText(statement, 0), let harness = Harness(rawValue: raw) else {
                continue
            }
            counts[harness] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    public func sessionCount() throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM sessions", []) ?? 0)
    }

    public func messageCount() throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM session_messages", []) ?? 0)
    }

    /// Substring search over indexed message bodies *and* session
    /// metadata, best match first, at most one hit per session.
    public func search(
        text: String,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        scopes: Set<SessionSearchScope> = SessionSearchScope.defaultScopes,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        limit: Int = 50
    ) throws -> [SessionSearchHit] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        if let providers, providers.isEmpty { return [] }
        if let harnesses, harnesses.isEmpty { return [] }
        guard !scopes.isEmpty else { return [] }
        let cap = min(max(1, limit), 500)
        let scope = Scope(
            providers: providers,
            harnesses: harnesses,
            searchScopes: scopes,
            projectIncludes: projectIncludes,
            projectExcludes: projectExcludes
        )

        var hits: [SessionSearchHit] = []
        var seen: Set<Int64> = []
        if scopes.contains(where: { $0.messageRole != nil }) {
            for row in try bodyMatches(needle, scope: scope, limit: cap) {
                guard seen.insert(row.rowID).inserted else { continue }
                hits.append(row.hit)
                if hits.count >= cap { return hits }
            }
        }
        if scopes.contains(.title) {
            for row in try metadataMatches(needle, scope: scope, limit: cap) {
                guard seen.insert(row.rowID).inserted else { continue }
                hits.append(row.hit)
                if hits.count >= cap { return hits }
            }
        }
        return hits
    }

    /// The trigram tokenizer indexes three-character sequences, so a
    /// one- or two-character query has nothing to match against. Those
    /// fall back to a bounded `LIKE` scan, which is slow in principle and
    /// fine in practice at this table's size.
    static let minimumTrigramLength = 3
    private static let likeScanLimit = 200

    /// What a search is narrowed to. Both dimensions are optional and are
    /// ANDed, which is what lets a company chip (harnesses) and an explicit
    /// provider list live in the same query.
    private struct Scope {
        let providers: [SessionProvider]?
        let harnesses: [Harness]?
        let searchScopes: Set<SessionSearchScope>
        let projectIncludes: [String]
        let projectExcludes: [String]
    }

    private func bodyMatches(
        _ needle: String,
        scope: Scope,
        limit: Int
    ) throws -> [(rowID: Int64, hit: SessionSearchHit)] {
        let filter = scopeFilter(scope, includeMessageRoles: true)
        let sql: String
        var bindings: [Binding]
        if needle.count >= Self.minimumTrigramLength {
            sql = """
                SELECT \(Self.sessionColumns), s.id, m.seq,
                       snippet(session_fts, 0, '<b>', '</b>', '…', 12)
                  FROM session_fts
                  JOIN session_messages m ON m.id = session_fts.rowid
                  JOIN sessions s ON s.id = m.session_row
                 WHERE session_fts MATCH ?\(filter.sql)
                 ORDER BY rank LIMIT ?
                """
            bindings = [.text(Self.ftsQuery(needle))] + filter.bindings + [.integer(Int64(limit))]
        } else {
            sql = """
                SELECT \(Self.sessionColumns), s.id, m.seq, m.excerpt
                  FROM session_messages m
                  JOIN sessions s ON s.id = m.session_row
                 WHERE m.excerpt LIKE ? ESCAPE '\\'\(filter.sql)
                 ORDER BY m.id LIMIT ?
                """
            bindings = [.text("%" + Self.likePattern(needle) + "%")]
                + filter.bindings
                + [.integer(Int64(min(limit, Self.likeScanLimit)))]
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)

        var out: [(rowID: Int64, hit: SessionSearchHit)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let summary = summary(statement, offset: 0) else { continue }
            out.append((
                sqlite3_column_int64(statement, Self.rowIDColumn),
                SessionSearchHit(
                    summary: summary,
                    snippet: columnText(statement, Self.rowIDColumn + 2),
                    matchedSeq: Int(sqlite3_column_int64(statement, Self.rowIDColumn + 1))
                )
            ))
        }
        return out
    }

    private func metadataMatches(
        _ needle: String,
        scope: Scope,
        limit: Int
    ) throws -> [(rowID: Int64, hit: SessionSearchHit)] {
        let filter = scopeFilter(scope, includeMessageRoles: false)
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns), s.id FROM sessions s
             WHERE (s.title LIKE ? ESCAPE '\\'
                 OR s.session_id LIKE ? ESCAPE '\\')\(filter.sql)
             ORDER BY s.last_active_at IS NULL, s.last_active_at DESC, s.id DESC
             LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        let pattern = "%" + Self.likePattern(needle) + "%"
        bindAll(
            [.text(pattern), .text(pattern)]
                + filter.bindings
                + [.integer(Int64(limit))],
            to: statement
        )

        var out: [(rowID: Int64, hit: SessionSearchHit)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let summary = summary(statement, offset: 0) else { continue }
            out.append((
                sqlite3_column_int64(statement, Self.rowIDColumn),
                SessionSearchHit(summary: summary, snippet: nil, matchedSeq: nil)
            ))
        }
        return out
    }

    private func scopeFilter(
        _ scope: Scope,
        includeMessageRoles: Bool
    ) -> (sql: String, bindings: [Binding]) {
        var sql = ""
        var bindings: [Binding] = []
        if let providers = scope.providers, !providers.isEmpty {
            let marks = Array(repeating: "?", count: providers.count).joined(separator: ", ")
            sql += " AND s.provider IN (\(marks))"
            bindings.append(contentsOf: providers.map { .text($0.rawValue) })
        }
        if let harnesses = scope.harnesses, !harnesses.isEmpty {
            let marks = Array(repeating: "?", count: harnesses.count).joined(separator: ", ")
            sql += " AND s.harness IN (\(marks))"
            bindings.append(contentsOf: harnesses.map { .text($0.rawValue) })
        }
        let roles = scope.searchScopes.compactMap(\.messageRole)
        if includeMessageRoles, !roles.isEmpty {
            let marks = Array(repeating: "?", count: roles.count).joined(separator: ", ")
            sql += " AND m.role IN (\(marks))"
            bindings.append(contentsOf: roles.map { .text($0.rawValue) })
        }
        var projectClauses: [String] = []
        Self.appendProjectClauses(
            includes: scope.projectIncludes,
            excludes: scope.projectExcludes,
            clauses: &projectClauses,
            bindings: &bindings
        )
        if !projectClauses.isEmpty {
            sql += " AND " + projectClauses.joined(separator: " AND ")
        }
        return (sql, bindings)
    }

    private static func appendProjectClauses(
        includes: [String],
        excludes: [String],
        clauses: inout [String],
        bindings: inout [Binding]
    ) {
        let included = includes.compactMap { SessionParsing.string($0) }
        if !included.isEmpty {
            clauses.append("(" + Array(repeating: "s.project_dir LIKE ? ESCAPE '\\'", count: included.count)
                .joined(separator: " OR ") + ")")
            bindings.append(contentsOf: included.map { .text("%" + likePattern($0) + "%") })
        }
        for excluded in excludes.compactMap({ SessionParsing.string($0) }) {
            clauses.append("(s.project_dir IS NULL OR s.project_dir NOT LIKE ? ESCAPE '\\')")
            bindings.append(.text("%" + likePattern(excluded) + "%"))
        }
    }

    /// One exact session row, used by hosts to resolve a related child hit
    /// (for example an Auto Review rollout) back to its root conversation.
    public func summary(provider: SessionProvider, sessionID: String) throws -> SessionSummary? {
        let statement = try prepare(
            "SELECT \(Self.sessionColumns) FROM sessions s WHERE s.provider = ? AND s.session_id = ? "
                + "ORDER BY COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bindAll([.text(provider.rawValue), .text(sessionID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return summary(statement, offset: 0)
    }

    /// Provider-specific related rows. The prefix is escaped as data, never
    /// interpolated as SQL, and the bounded result protects UI callers from
    /// accidentally loading an unbounded archive.
    public func summaries(
        provider: SessionProvider,
        providerVariantPrefix: String,
        limit: Int = 2_000
    ) throws -> [SessionSummary] {
        let cap = min(max(1, limit), 10_000)
        let statement = try prepare(
            "SELECT \(Self.sessionColumns) FROM sessions s WHERE s.provider = ? "
                + "AND s.provider_variant LIKE ? ESCAPE '\\' "
                + "ORDER BY COALESCE(s.last_active_at, s.created_at) ASC, s.id ASC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        bindAll([
            .text(provider.rawValue),
            .text(Self.likePattern(providerVariantPrefix) + "%"),
            .integer(Int64(cap))
        ], to: statement)
        var out: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = summary(statement, offset: 0) { out.append(value) }
        }
        return out
    }

    /// FTS5 `MATCH` takes a query language, not a literal: bare `AND`,
    /// `*`, `:`, `-` and friends are operators. Wrapping the whole needle
    /// in double quotes turns it into one phrase, and doubling any
    /// embedded quote keeps that wrapper from being closed early — so no
    /// user input can reach the parser as syntax.
    static func ftsQuery(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `LIKE` wildcards escaped against a literal `\` escape character.
    static func likePattern(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Row decoding

    private func summary(_ statement: OpaquePointer, offset: Int32) -> SessionSummary? {
        guard let rawProvider = columnText(statement, offset),
              let provider = SessionProvider(rawValue: rawProvider),
              let sessionID = columnText(statement, offset + 1),
              let sourcePath = columnText(statement, offset + 8)
        else { return nil }
        return SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: columnText(statement, offset + 2),
            harness: columnText(statement, offset + 11).flatMap(Harness.init(rawValue:)),
            model: columnText(statement, offset + 12),
            title: columnText(statement, offset + 3),
            summary: columnText(statement, offset + 4),
            projectDir: columnText(statement, offset + 5),
            createdAt: date(statement, offset + 6),
            lastActiveAt: date(statement, offset + 7),
            sourcePath: sourcePath,
            sizeBytes: sqlite3_column_int64(statement, offset + 9),
            messageCount: Int(sqlite3_column_int64(statement, offset + 10))
        )
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)))
    }

    private static func epoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int64)
        case null
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionIndexError.statement
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if statement != nil { sqlite3_finalize(statement) }
            throw SessionIndexError.statement
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionIndexError.statement
        }
    }

    private func scalarInt(_ sql: String, _ bindings: [Binding]) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SessionIndexError.statement }
        return sqlite3_column_int64(statement, 0)
    }

    private func bindAll(_ bindings: [Binding], to statement: OpaquePointer) {
        for (index, value) in bindings.enumerated() {
            switch value {
            case let .text(text):
                sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case let .integer(integer):
                sqlite3_bind_int64(statement, Int32(index + 1), integer)
            case .null:
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
