//! Read-only access to the shared session index (`session_index.sqlite3`).
//!
//! Contract: schema is `PRAGMA user_version = 5`, owned and rebuilt by the
//! index writer (the Swift `SessionIndexStore` today). This reader opens the
//! database with `SQLITE_OPEN_READONLY`, checks the version, and refuses
//! anything it does not understand — it must never trigger schema creation,
//! migration, prune, or rebuild.

use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde::Serialize;

use crate::error::SessionCoreError;
use crate::provider::SessionProvider;

pub const SUPPORTED_SCHEMA_VERSION: i64 = 5;

/// One row of the `sessions` table, in display order.
#[derive(Debug, Clone, Serialize)]
pub struct SessionSummary {
    /// Index rowid — stable within one index generation only.
    pub row_id: i64,
    pub provider: SessionProvider,
    pub session_id: String,
    pub provider_variant: Option<String>,
    pub harness: Option<String>,
    pub model: Option<String>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub project_dir: Option<String>,
    /// Unix epoch seconds.
    pub created_at: Option<i64>,
    /// Unix epoch seconds.
    pub last_active_at: Option<i64>,
    pub source_path: String,
    pub size_bytes: Option<i64>,
    pub message_count: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionSearchHit {
    pub session: SessionSummary,
    /// Message sequence the excerpt came from (None for title-only hits).
    pub seq: Option<i64>,
    pub excerpt: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranscriptExcerpt {
    pub seq: i64,
    pub role: String,
    pub excerpt: String,
}

#[derive(Debug, Clone, Default)]
pub struct SessionListFilter {
    /// None = all providers; empty = matches nothing (mirrors Swift).
    pub providers: Option<Vec<SessionProvider>>,
    /// Harness display names ("Codex", "Claude Code", …).
    pub harnesses: Option<Vec<String>>,
    /// Only sessions active at/after this Unix timestamp.
    pub since: Option<i64>,
    pub limit: usize,
    pub offset: usize,
}

pub struct SessionIndexReader {
    conn: Connection,
    path: PathBuf,
}

impl SessionIndexReader {
    /// Opens the index read-only. Fails closed on a missing file or an
    /// unsupported schema version.
    pub fn open(path: &Path) -> Result<Self, SessionCoreError> {
        if !path.is_file() {
            return Err(SessionCoreError::IndexNotFound(
                path.to_string_lossy().into_owned(),
            ));
        }
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(std::time::Duration::from_millis(5_000))?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != SUPPORTED_SCHEMA_VERSION {
            return Err(SessionCoreError::UnsupportedIndexSchema {
                found: version,
                expected: SUPPORTED_SCHEMA_VERSION,
            });
        }
        Ok(Self {
            conn,
            path: path.to_path_buf(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn session_count(&self) -> Result<i64, SessionCoreError> {
        Ok(self
            .conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))?)
    }

    /// Recent sessions, newest activity first (mirrors the Swift store's
    /// `COALESCE(last_active_at, created_at) DESC, id DESC` ordering).
    pub fn list(&self, filter: &SessionListFilter) -> Result<Vec<SessionSummary>, SessionCoreError> {
        let (where_sql, params) = Self::filter_clause(filter);
        let sql = format!(
            "SELECT {cols} FROM sessions s WHERE 1=1{where_sql} \
             ORDER BY COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC \
             LIMIT ? OFFSET ?",
            cols = Self::SESSION_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut bind: Vec<Box<dyn rusqlite::ToSql>> = params;
        bind.push(Box::new(filter.limit.max(1) as i64));
        bind.push(Box::new(filter.offset as i64));
        let rows = stmt.query_map(
            rusqlite::params_from_iter(bind.iter().map(|b| b.as_ref())),
            Self::row_to_summary,
        )?;
        let mut out = Vec::new();
        for row in rows {
            if let Some(summary) = row? {
                out.push(summary);
            }
        }
        Ok(out)
    }

    /// Full-text search over indexed excerpts. Mirrors the Swift store:
    /// needles of three or more characters go through the trigram FTS table
    /// as one quoted phrase; shorter needles fall back to an escaped `LIKE`.
    pub fn search(
        &self,
        text: &str,
        filter: &SessionListFilter,
    ) -> Result<Vec<SessionSearchHit>, SessionCoreError> {
        let needle = text.trim();
        if needle.is_empty() {
            return Ok(Vec::new());
        }
        let (where_sql, params) = Self::filter_clause(filter);
        let limit = filter.limit.max(1) as i64;

        let use_fts = needle.chars().count() >= 3;
        let sql = if use_fts {
            format!(
                "SELECT {cols}, m.seq, m.excerpt \
                   FROM session_fts f \
                   JOIN session_messages m ON m.id = f.rowid \
                   JOIN sessions s ON s.id = m.session_row \
                  WHERE session_fts MATCH ?{where_sql} \
                  ORDER BY rank LIMIT ?",
                cols = Self::SESSION_COLUMNS
            )
        } else {
            format!(
                "SELECT {cols}, m.seq, m.excerpt \
                   FROM session_messages m \
                   JOIN sessions s ON s.id = m.session_row \
                  WHERE m.excerpt LIKE ? ESCAPE '\\'{where_sql} \
                  ORDER BY m.id LIMIT ?",
                cols = Self::SESSION_COLUMNS
            )
        };
        let needle_binding: String = if use_fts {
            Self::fts_query(needle)
        } else {
            format!("%{}%", Self::like_pattern(needle))
        };

        let mut stmt = self.conn.prepare(&sql)?;
        let mut bind: Vec<Box<dyn rusqlite::ToSql>> = Vec::with_capacity(params.len() + 2);
        bind.push(Box::new(needle_binding));
        bind.extend(params);
        bind.push(Box::new(limit));
        let rows = stmt.query_map(
            rusqlite::params_from_iter(bind.iter().map(|b| b.as_ref())),
            |row| {
                let summary = Self::row_to_summary(row)?;
                let seq: Option<i64> = row.get(Self::COLUMN_COUNT)?;
                let excerpt: String = row.get(Self::COLUMN_COUNT + 1)?;
                Ok(summary.map(|session| SessionSearchHit {
                    session,
                    seq,
                    excerpt,
                }))
            },
        )?;
        let mut out = Vec::new();
        for row in rows {
            if let Some(hit) = row? {
                out.push(hit);
            }
        }
        Ok(out)
    }

    /// Indexed message excerpts for one session row, paged by `seq`.
    pub fn excerpts(
        &self,
        session_row: i64,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<TranscriptExcerpt>, SessionCoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT seq, role, excerpt FROM session_messages \
             WHERE session_row = ? ORDER BY seq LIMIT ? OFFSET ?",
        )?;
        let rows = stmt.query_map(
            rusqlite::params![session_row, limit.max(1) as i64, offset as i64],
            |row| {
                Ok(TranscriptExcerpt {
                    seq: row.get(0)?,
                    role: row.get(1)?,
                    excerpt: row.get(2)?,
                })
            },
        )?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    const SESSION_COLUMNS: &'static str = "s.id, s.provider, s.session_id, s.provider_variant, \
        s.harness, s.model, s.title, s.summary, s.project_dir, s.created_at, s.last_active_at, \
        s.source_path, s.size_bytes, s.message_count";
    const COLUMN_COUNT: usize = 14;

    fn filter_clause(
        filter: &SessionListFilter,
    ) -> (String, Vec<Box<dyn rusqlite::ToSql>>) {
        let mut sql = String::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(providers) = &filter.providers {
            if providers.is_empty() {
                // Empty selection matches nothing — mirror the Swift contract.
                sql.push_str(" AND 0");
            } else {
                let marks = vec!["?"; providers.len()].join(",");
                sql.push_str(&format!(" AND s.provider IN ({marks})"));
                for p in providers {
                    params.push(Box::new(p.raw_value().to_string()));
                }
            }
        }
        if let Some(harnesses) = &filter.harnesses {
            if harnesses.is_empty() {
                sql.push_str(" AND 0");
            } else {
                let marks = vec!["?"; harnesses.len()].join(",");
                sql.push_str(&format!(" AND s.harness IN ({marks})"));
                for h in harnesses {
                    params.push(Box::new(h.clone()));
                }
            }
        }
        if let Some(since) = filter.since {
            sql.push_str(" AND COALESCE(s.last_active_at, s.created_at) >= ?");
            params.push(Box::new(since));
        }
        (sql, params)
    }

    fn row_to_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<Option<SessionSummary>> {
        let raw_provider: String = row.get(1)?;
        let Some(provider) = SessionProvider::from_raw(&raw_provider) else {
            // Unknown provider rows are skipped, not errors — a newer writer
            // may know providers this reader does not.
            return Ok(None);
        };
        Ok(Some(SessionSummary {
            row_id: row.get(0)?,
            provider,
            session_id: row.get(2)?,
            provider_variant: row.get(3)?,
            harness: row.get(4)?,
            model: row.get(5)?,
            title: row.get(6)?,
            summary: row.get(7)?,
            project_dir: row.get(8)?,
            created_at: row.get(9)?,
            last_active_at: row.get(10)?,
            source_path: row.get(11)?,
            size_bytes: row.get(12)?,
            message_count: row.get(13)?,
        }))
    }

    /// Mirrors Swift `SessionIndexStore.ftsQuery` — one quoted phrase.
    fn fts_query(raw: &str) -> String {
        format!("\"{}\"", raw.replace('"', "\"\""))
    }

    /// Mirrors Swift `SessionIndexStore.likePattern`.
    fn like_pattern(raw: &str) -> String {
        raw.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_index(dir: &Path) -> PathBuf {
        let path = dir.join("session_index.sqlite3");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            r#"
            PRAGMA user_version = 5;
            CREATE TABLE session_index_meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE sessions(
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
                size_bytes INTEGER,
                message_count INTEGER,
                UNIQUE(provider, session_id, source_path)
            );
            CREATE TABLE session_messages(
                id INTEGER PRIMARY KEY,
                session_row INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL,
                role TEXT NOT NULL,
                excerpt TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE session_fts USING fts5(
                excerpt, content='session_messages', content_rowid='id', tokenize='trigram'
            );
            CREATE TRIGGER session_messages_ai AFTER INSERT ON session_messages BEGIN
                INSERT INTO session_fts(rowid, excerpt) VALUES (new.id, new.excerpt);
            END;
            INSERT INTO sessions(id, provider, session_id, harness, title, project_dir,
                                 created_at, last_active_at, source_path, message_count)
            VALUES
              (1, 'codex', 'aaaa1111-0000-0000-0000-000000000001', 'Codex',
               'Fix the tray icon', '/Users/example/proj', 1700000000, 1700000500,
               '/Users/example/.codex/sessions/a.jsonl', 4),
              (2, 'claude', 'bbbb2222-0000-0000-0000-000000000002', 'Claude Code',
               'Refactor storage layer', '/Users/example/proj2', 1700001000, 1700002000,
               '/Users/example/.claude/projects/p/b.jsonl', 6),
              (3, 'unknown-future-provider', 'cccc', 'Future', 'x', '/x',
               1700003000, 1700003000, '/x.jsonl', 1);
            INSERT INTO session_messages(id, session_row, seq, role, excerpt) VALUES
              (10, 1, 0, 'user', 'please fix the tray icon rendering bug'),
              (11, 1, 1, 'assistant', 'sure, the tray title needs an update'),
              (12, 2, 0, 'user', 'refactor the sqlite storage layer');
            "#,
        )
        .unwrap();
        path
    }

    #[test]
    fn refuses_wrong_schema_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("idx.sqlite3");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("PRAGMA user_version = 4; CREATE TABLE sessions(id);")
            .unwrap();
        drop(conn);
        match SessionIndexReader::open(&path) {
            Err(SessionCoreError::UnsupportedIndexSchema { found: 4, expected: 5 }) => {}
            Err(other) => panic!("unexpected error: {other:?}"),
            Ok(_) => panic!("open unexpectedly succeeded"),
        }
    }

    #[test]
    fn lists_and_skips_unknown_providers() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        assert_eq!(reader.session_count().unwrap(), 3);
        let rows = reader
            .list(&SessionListFilter { limit: 10, ..Default::default() })
            .unwrap();
        // Unknown provider row is skipped; newest first.
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].provider, SessionProvider::Claude);
        assert_eq!(rows[1].provider, SessionProvider::Codex);
    }

    #[test]
    fn provider_filter_and_empty_selection() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let only_codex = reader
            .list(&SessionListFilter {
                providers: Some(vec![SessionProvider::Codex]),
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(only_codex.len(), 1);
        let none = reader
            .list(&SessionListFilter {
                providers: Some(vec![]),
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn fts_and_like_search() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let hits = reader
            .search("tray", &SessionListFilter { limit: 10, ..Default::default() })
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].session.provider, SessionProvider::Codex);
        // Two-char needle → LIKE path.
        let like_hits = reader
            .search("sq", &SessionListFilter { limit: 10, ..Default::default() })
            .unwrap();
        assert_eq!(like_hits.len(), 1);
        assert_eq!(like_hits[0].session.provider, SessionProvider::Claude);
    }

    #[test]
    fn excerpts_page() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let page = reader.excerpts(1, 0, 10).unwrap();
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].role, "user");
        assert_eq!(page[1].seq, 1);
    }
}
