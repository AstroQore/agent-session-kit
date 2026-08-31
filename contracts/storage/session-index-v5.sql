-- Session index, schema version 5.
--
-- Canonical DDL for `session_index.sqlite3`. Both implementation lanes are
-- checked against this file: the Swift writer creates exactly these objects,
-- and the Rust reader refuses any database whose `PRAGMA user_version` is not
-- 5 rather than rebuilding it.
--
-- The index is derived data. A host may delete the file and pay a re-scan, so
-- a version bump is a re-index, never a migration. Changing anything here is
-- therefore a coordinated change across both lanes plus a kit minor version.

PRAGMA user_version = 5;

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
