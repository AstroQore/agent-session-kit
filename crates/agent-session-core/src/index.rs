//! Read-only access to the shared session index (`session_index.sqlite3`).
//!
//! Contract: schema is `PRAGMA user_version = 5`, owned and rebuilt by the
//! index writer (the Swift `SessionIndexStore` today). This reader opens the
//! database with `SQLITE_OPEN_READONLY`, checks the version, and refuses
//! anything it does not understand — it must never trigger schema creation,
//! migration, prune, or rebuild.
//!
//! One caveat worth stating plainly, because it looks like a write and isn't:
//! opening a WAL database read-only still mmaps its `-shm` sibling, which
//! updates that file's mtime. The database file and the `-wal` are untouched
//! (verified byte-for-byte against a live 12.8k-session index). A host
//! auditing "did the second client write anything?" should expect exactly
//! this one mtime bump and nothing else. Opening with `immutable=1` would
//! avoid even that, but at the cost of not seeing rows the writer has
//! committed to the WAL and not yet checkpointed — a stale read is the worse
//! trade.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde::Serialize;

use crate::error::SessionCoreError;
use crate::provider::SessionProvider;
use crate::transcript::{self, TranscriptPage};

pub const SUPPORTED_SCHEMA_VERSION: i64 = 5;
/// Matches the Swift store's public page/search cap.
pub const MAX_QUERY_LIMIT: usize = 500;
/// Matches the Swift store's deliberately smaller short-needle LIKE cap.
pub const MAX_LIKE_SEARCH_LIMIT: usize = 200;
/// Prevent a hostile request from turning OFFSET into an expensive scan.
pub const MAX_QUERY_OFFSET: usize = 1_000_000;
/// A list of provider or harness filters can never generate more bind slots
/// than this. UI filters should be far smaller in normal use.
pub const MAX_FILTER_VALUES: usize = 64;

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
    /// Internal source location. It is metadata, not an authorization token:
    /// hosts must never accept this value back from an untrusted caller.
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

/// A backend-only row reference in the current index generation.
///
/// This is a predictable SQLite row id, not an unforgeable capability. Hosts
/// must keep a random, reader-local UI token map and resolve it to this type
/// only inside their trusted backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionRef(pub i64);

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProviderCompatibility {
    /// Provider raw values present in the index but unknown to this crate.
    pub unknown_providers: Vec<String>,
    /// Sessions omitted from normal rows because their provider is unknown.
    pub unknown_session_count: i64,
}

#[derive(Debug, Clone, Default)]
pub struct SessionListFilter {
    /// None = all providers; empty = matches nothing (mirrors Swift).
    pub providers: Option<Vec<SessionProvider>>,
    /// Harness display names ("Codex", "Claude Code", …).
    pub harnesses: Option<Vec<String>>,
    /// Only sessions active at/after this Unix timestamp.
    pub since: Option<i64>,
    /// Only sessions active at/before this Unix timestamp (inclusive).
    pub until: Option<i64>,
    pub limit: usize,
    pub offset: usize,
}

/// Which indexed parts a search may match. Project paths deliberately are not
/// a scope: callers narrow them with `project_includes` and
/// `project_excludes`, matching the Swift store's contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionSearchScope {
    Title,
    User,
    Assistant,
    System,
    Tool,
}

impl SessionSearchScope {
    fn message_role(self) -> Option<&'static str> {
        match self {
            Self::Title => None,
            Self::User => Some("user"),
            Self::Assistant => Some("assistant"),
            Self::System => Some("system"),
            Self::Tool => Some("tool"),
        }
    }
}

/// Narrowing and scope selection for [`SessionIndexReader::search_with_filter`].
///
/// The default deliberately excludes system and tool excerpts. They can carry
/// commands, file names, and other incidental text that should not become a
/// surprising ordinary search hit; callers opt into them explicitly.
#[derive(Debug, Clone)]
pub struct SessionSearchFilter {
    pub providers: Option<Vec<SessionProvider>>,
    pub harnesses: Option<Vec<String>>,
    /// Only sessions active at/after this Unix timestamp. Kept here so the
    /// legacy `search(text, SessionListFilter)` adapter cannot silently drop
    /// its existing `since` constraint.
    pub since: Option<i64>,
    /// Only sessions active at/before this Unix timestamp (inclusive).
    pub until: Option<i64>,
    /// Defaults to title, user, and assistant, mirroring Swift.
    pub scopes: BTreeSet<SessionSearchScope>,
    /// Substring filters over `sessions.project_dir`; any include may match.
    pub project_includes: Vec<String>,
    /// Substring filters over `sessions.project_dir`; every exclusion applies.
    pub project_excludes: Vec<String>,
    pub limit: usize,
}

impl Default for SessionSearchFilter {
    fn default() -> Self {
        Self {
            providers: None,
            harnesses: None,
            since: None,
            until: None,
            scopes: [
                SessionSearchScope::Title,
                SessionSearchScope::User,
                SessionSearchScope::Assistant,
            ]
            .into_iter()
            .collect(),
            project_includes: Vec::new(),
            project_excludes: Vec::new(),
            limit: 50,
        }
    }
}

impl From<&SessionListFilter> for SessionSearchFilter {
    fn from(filter: &SessionListFilter) -> Self {
        Self {
            providers: filter.providers.clone(),
            harnesses: filter.harnesses.clone(),
            since: filter.since,
            until: filter.until,
            limit: filter.limit,
            ..Self::default()
        }
    }
}

pub struct SessionIndexReader {
    conn: Connection,
    path: PathBuf,
}

impl SessionIndexReader {
    /// Opens the index read-only. Fails closed on a missing file, symlinked or
    /// non-regular leaf, or unsupported schema version. This portable leaf
    /// check cannot eliminate a same-user path replacement race; hosts should
    /// construct this path internally, never from untrusted IPC input.
    pub fn open(path: &Path) -> Result<Self, SessionCoreError> {
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(SessionCoreError::IndexNotFound(
                    path.to_string_lossy().into_owned(),
                ));
            }
            Err(error) => return Err(error.into()),
        };
        if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
            return Err(SessionCoreError::UnsafePath(
                path.to_string_lossy().into_owned(),
            ));
        }
        if !metadata.is_file() {
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

    /// Number of sessions whose provider this crate understands. Consult
    /// [`provider_compatibility`](Self::provider_compatibility) alongside it
    /// before presenting the result as a complete index.
    pub fn session_count(&self) -> Result<i64, SessionCoreError> {
        let providers = Self::provider_placeholders();
        Ok(self.conn.query_row(
            &format!("SELECT COUNT(*) FROM sessions WHERE provider IN ({providers})"),
            [],
            |r| r.get(0),
        )?)
    }

    /// Makes a forward provider-contract mismatch visible instead of silently
    /// presenting a partial list as the complete index.
    pub fn provider_compatibility(&self) -> Result<ProviderCompatibility, SessionCoreError> {
        let providers = Self::provider_placeholders();
        let mut stmt = self.conn.prepare(&format!(
            "SELECT provider, COUNT(*) FROM sessions WHERE provider NOT IN ({providers}) GROUP BY provider ORDER BY provider"
        ))?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut unknown_providers = Vec::new();
        let mut unknown_session_count = 0;
        for row in rows {
            let (provider, count) = row?;
            unknown_providers.push(provider);
            unknown_session_count += count;
        }
        Ok(ProviderCompatibility {
            unknown_providers,
            unknown_session_count,
        })
    }

    /// Recent sessions, newest activity first (mirrors the Swift store's
    /// `COALESCE(last_active_at, created_at) DESC, id DESC` ordering).
    pub fn list(
        &self,
        filter: &SessionListFilter,
    ) -> Result<Vec<SessionSummary>, SessionCoreError> {
        let (where_sql, params) = Self::filter_clause(filter)?;
        let sql = format!(
            "SELECT {cols} FROM sessions s WHERE {known}{where_sql} \
             ORDER BY COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC \
             LIMIT ? OFFSET ?",
            cols = Self::SESSION_COLUMNS,
            known = Self::known_provider_predicate(),
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut bind: Vec<Box<dyn rusqlite::ToSql>> = params;
        bind.push(Box::new(Self::bounded_limit(filter.limit)));
        bind.push(Box::new(Self::bounded_offset(filter.offset)));
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
        self.search_with_filter(text, &SessionSearchFilter::from(filter))
    }

    /// Scoped transcript and title search. This is the Rust equivalent of
    /// Swift `SessionIndexStore.search`: title/session-id metadata only joins
    /// when `Title` is enabled; body rows only join when their exact role is
    /// enabled; project filters apply to both branches.
    pub fn search_with_filter(
        &self,
        text: &str,
        filter: &SessionSearchFilter,
    ) -> Result<Vec<SessionSearchHit>, SessionCoreError> {
        let needle = text.trim();
        if needle.is_empty() || filter.scopes.is_empty() {
            return Ok(Vec::new());
        }
        let (where_sql, params) = Self::search_filter_clause(filter, true)?;
        let limit = Self::bounded_limit(filter.limit);

        let use_fts = needle.chars().count() >= 3;
        let has_message_scope = filter
            .scopes
            .iter()
            .any(|scope| scope.message_role().is_some());
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        if has_message_scope {
            let sql = if use_fts {
                format!(
                    "WITH body_matches AS ( \
                   SELECT {cols}, m.seq, m.excerpt, rank AS sort_key, \
                          ROW_NUMBER() OVER (PARTITION BY s.id ORDER BY rank) AS row_rank \
                     FROM session_fts f \
                     JOIN session_messages m ON m.id = f.rowid \
                     JOIN sessions s ON s.id = m.session_row \
                    WHERE session_fts MATCH ? AND {known}{where_sql} \
                 ) SELECT {cols_no_alias}, seq, excerpt FROM body_matches \
                   WHERE row_rank = 1 ORDER BY sort_key LIMIT ?",
                    cols = Self::cte_session_columns(),
                    cols_no_alias = Self::cte_output_columns(),
                    known = Self::known_provider_predicate(),
                )
            } else {
                format!(
                    "WITH body_matches AS ( \
                   SELECT {cols}, m.seq, m.excerpt, m.id AS sort_key, \
                          ROW_NUMBER() OVER (PARTITION BY s.id ORDER BY m.id) AS row_rank \
                     FROM session_messages m \
                     JOIN sessions s ON s.id = m.session_row \
                    WHERE m.excerpt LIKE ? ESCAPE '\\' AND {known}{where_sql} \
                 ) SELECT {cols_no_alias}, seq, excerpt FROM body_matches \
                   WHERE row_rank = 1 ORDER BY sort_key LIMIT ?",
                    cols = Self::cte_session_columns(),
                    cols_no_alias = Self::cte_output_columns(),
                    known = Self::known_provider_predicate(),
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
            bind.push(Box::new(Self::bounded_search_limit(limit, use_fts)));
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
            for row in rows {
                if let Some(hit) = row? {
                    if seen.insert(hit.session.row_id) {
                        out.push(hit);
                    }
                    if out.len() >= limit as usize {
                        return Ok(out);
                    }
                }
            }
        }

        // Metadata is a title scope, not a fallback which can leak a title
        // into a role-only search. Session id shares the title branch in Swift.
        if !filter.scopes.contains(&SessionSearchScope::Title) {
            return Ok(out);
        }
        let (metadata_where_sql, metadata_params) = Self::search_filter_clause(filter, false)?;
        let metadata_sql = format!(
            "SELECT {cols}, NULL AS seq, NULL AS excerpt FROM sessions s \
             WHERE {known} AND (s.title LIKE ? ESCAPE '\\' OR s.session_id LIKE ? ESCAPE '\\'){metadata_where_sql} \
             ORDER BY s.last_active_at IS NULL, s.last_active_at DESC, s.id DESC LIMIT ?",
            cols = Self::SESSION_COLUMNS,
            known = Self::known_provider_predicate(),
        );
        let pattern = format!("%{}%", Self::like_pattern(needle));
        let mut metadata_bind: Vec<Box<dyn rusqlite::ToSql>> =
            Vec::with_capacity(metadata_params.len() + 3);
        metadata_bind.push(Box::new(pattern.clone()));
        metadata_bind.push(Box::new(pattern));
        metadata_bind.extend(metadata_params);
        metadata_bind.push(Box::new(limit));
        let mut metadata_stmt = self.conn.prepare(&metadata_sql)?;
        let metadata_rows = metadata_stmt.query_map(
            rusqlite::params_from_iter(metadata_bind.iter().map(|b| b.as_ref())),
            |row| {
                let summary = Self::row_to_summary(row)?;
                let seq: Option<i64> = row.get(Self::COLUMN_COUNT)?;
                let excerpt: Option<String> = row.get(Self::COLUMN_COUNT + 1)?;
                Ok(summary.map(|session| SessionSearchHit {
                    session,
                    seq,
                    excerpt: excerpt.unwrap_or_default(),
                }))
            },
        )?;
        for row in metadata_rows {
            if let Some(hit) = row? {
                if seen.insert(hit.session.row_id) {
                    out.push(hit);
                }
                if out.len() >= limit as usize {
                    break;
                }
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
            rusqlite::params![
                session_row,
                Self::bounded_limit(limit),
                Self::bounded_offset(offset),
            ],
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

    /// Backend convenience for a known index row.
    ///
    /// This resolves the stored source path and uses the path convenience
    /// reader, so it is best-effort against same-user path replacement. A
    /// security-sensitive host should resolve its own random UI token to a
    /// backend row, safely open the resulting file, then call
    /// [`transcript::read_page_from_file`].
    pub fn read_transcript_page(
        &self,
        session: SessionRef,
        offset: usize,
        limit: usize,
    ) -> Result<TranscriptPage, SessionCoreError> {
        let (raw_provider, source_path): (String, String) = self
            .conn
            .query_row(
                "SELECT provider, source_path FROM sessions WHERE id = ?",
                [session.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    SessionCoreError::SessionNotFound(session.0)
                }
                other => SessionCoreError::Sqlite(other),
            })?;
        let provider = SessionProvider::from_raw(&raw_provider)
            .ok_or(SessionCoreError::UnknownProvider(raw_provider))?;
        Ok(transcript::read_page(
            provider,
            Path::new(&source_path),
            offset,
            limit,
        )?)
    }

    const SESSION_COLUMNS: &'static str = "s.id, s.provider, s.session_id, s.provider_variant, \
        s.harness, s.model, s.title, s.summary, s.project_dir, s.created_at, s.last_active_at, \
        s.source_path, s.size_bytes, s.message_count";
    const COLUMN_COUNT: usize = 14;

    fn bounded_limit(limit: usize) -> i64 {
        limit.clamp(1, MAX_QUERY_LIMIT) as i64
    }

    fn bounded_offset(offset: usize) -> i64 {
        offset.min(MAX_QUERY_OFFSET) as i64
    }

    fn bounded_search_limit(limit: i64, use_fts: bool) -> i64 {
        if use_fts {
            limit
        } else {
            limit.min(MAX_LIKE_SEARCH_LIMIT as i64)
        }
    }

    fn provider_placeholders() -> String {
        SessionProvider::ALL
            .iter()
            .map(|provider| format!("'{}'", provider.raw_value()))
            .collect::<Vec<_>>()
            .join(",")
    }

    fn known_provider_predicate() -> String {
        format!("s.provider IN ({})", Self::provider_placeholders())
    }

    fn cte_session_columns() -> String {
        Self::SESSION_COLUMNS.replacen("s.id,", "s.id AS session_row_id,", 1)
    }

    fn cte_output_columns() -> String {
        Self::SESSION_COLUMNS
            .replace("s.id", "session_row_id")
            .replace("s.", "")
    }

    fn filter_clause(
        filter: &SessionListFilter,
    ) -> Result<(String, Vec<Box<dyn rusqlite::ToSql>>), SessionCoreError> {
        let mut sql = String::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(providers) = &filter.providers {
            let providers = Self::dedup_providers(providers)?;
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
            let harnesses = Self::dedup_harnesses(harnesses)?;
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
        if let Some(until) = filter.until {
            sql.push_str(
                " AND (COALESCE(s.last_active_at, s.created_at) IS NULL \
                 OR COALESCE(s.last_active_at, s.created_at) <= ?)",
            );
            params.push(Box::new(until));
        }
        Ok((sql, params))
    }

    fn search_filter_clause(
        filter: &SessionSearchFilter,
        include_message_roles: bool,
    ) -> Result<(String, Vec<Box<dyn rusqlite::ToSql>>), SessionCoreError> {
        let mut sql = String::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(providers) = &filter.providers {
            let providers = Self::dedup_providers(providers)?;
            if providers.is_empty() {
                sql.push_str(" AND 0");
            } else {
                let marks = vec!["?"; providers.len()].join(",");
                sql.push_str(&format!(" AND s.provider IN ({marks})"));
                for provider in providers {
                    params.push(Box::new(provider.raw_value().to_string()));
                }
            }
        }
        if let Some(harnesses) = &filter.harnesses {
            let harnesses = Self::dedup_harnesses(harnesses)?;
            if harnesses.is_empty() {
                sql.push_str(" AND 0");
            } else {
                let marks = vec!["?"; harnesses.len()].join(",");
                sql.push_str(&format!(" AND s.harness IN ({marks})"));
                for harness in harnesses {
                    params.push(Box::new(harness));
                }
            }
        }
        if let Some(since) = filter.since {
            sql.push_str(" AND COALESCE(s.last_active_at, s.created_at) >= ?");
            params.push(Box::new(since));
        }
        if let Some(until) = filter.until {
            sql.push_str(
                " AND (COALESCE(s.last_active_at, s.created_at) IS NULL \
                 OR COALESCE(s.last_active_at, s.created_at) <= ?)",
            );
            params.push(Box::new(until));
        }
        if include_message_roles {
            let roles: Vec<_> = filter
                .scopes
                .iter()
                .filter_map(|scope| scope.message_role())
                .collect();
            if !roles.is_empty() {
                let marks = vec!["?"; roles.len()].join(",");
                sql.push_str(&format!(" AND m.role IN ({marks})"));
                for role in roles {
                    params.push(Box::new(role.to_string()));
                }
            }
        }
        let includes = Self::dedup_nonempty_strings(&filter.project_includes, "project_includes")?;
        if !includes.is_empty() {
            let marks = vec!["s.project_dir LIKE ? ESCAPE '\\'"; includes.len()].join(" OR ");
            sql.push_str(&format!(" AND ({marks})"));
            for project in includes {
                params.push(Box::new(format!("%{}%", Self::like_pattern(&project))));
            }
        }
        let excludes = Self::dedup_nonempty_strings(&filter.project_excludes, "project_excludes")?;
        for project in excludes {
            sql.push_str(" AND (s.project_dir IS NULL OR s.project_dir NOT LIKE ? ESCAPE '\\')");
            params.push(Box::new(format!("%{}%", Self::like_pattern(&project))));
        }
        Ok((sql, params))
    }

    fn dedup_providers(
        providers: &[SessionProvider],
    ) -> Result<Vec<SessionProvider>, SessionCoreError> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for provider in providers {
            if seen.insert(*provider) {
                if out.len() == MAX_FILTER_VALUES {
                    return Err(SessionCoreError::FilterTooLarge {
                        field: "providers",
                        max: MAX_FILTER_VALUES,
                    });
                }
                out.push(*provider);
            }
        }
        Ok(out)
    }

    fn dedup_harnesses(harnesses: &[String]) -> Result<Vec<String>, SessionCoreError> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for harness in harnesses {
            if seen.insert(harness.as_str()) {
                if out.len() == MAX_FILTER_VALUES {
                    return Err(SessionCoreError::FilterTooLarge {
                        field: "harnesses",
                        max: MAX_FILTER_VALUES,
                    });
                }
                out.push(harness.clone());
            }
        }
        Ok(out)
    }

    fn dedup_nonempty_strings(
        values: &[String],
        field: &'static str,
    ) -> Result<Vec<String>, SessionCoreError> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for value in values {
            let value = value.trim();
            if value.is_empty() || !seen.insert(value) {
                continue;
            }
            if out.len() == MAX_FILTER_VALUES {
                return Err(SessionCoreError::FilterTooLarge {
                    field,
                    max: MAX_FILTER_VALUES,
                });
            }
            out.push(value.to_string());
        }
        Ok(out)
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
        raw.replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
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
            Err(SessionCoreError::UnsupportedIndexSchema {
                found: 4,
                expected: 5,
            }) => {}
            Err(other) => panic!("unexpected error: {other:?}"),
            Ok(_) => panic!("open unexpectedly succeeded"),
        }
    }

    #[test]
    fn read_only_open_leaves_the_database_bytes_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let before = std::fs::read(&path).unwrap();
        let reader = SessionIndexReader::open(&path).unwrap();
        assert_eq!(reader.session_count().unwrap(), 2);
        drop(reader);
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }

    #[test]
    fn lists_known_sessions_and_exposes_unknown_providers() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        assert_eq!(reader.session_count().unwrap(), 2);
        assert_eq!(
            reader.provider_compatibility().unwrap(),
            ProviderCompatibility {
                unknown_providers: vec!["unknown-future-provider".to_string()],
                unknown_session_count: 1,
            }
        );
        let rows = reader
            .list(&SessionListFilter {
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        // Unknown provider row is skipped; newest first.
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].provider, SessionProvider::Claude);
        assert_eq!(rows[1].provider, SessionProvider::Codex);
        let first = reader
            .list(&SessionListFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(first[0].provider, SessionProvider::Claude);
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
    fn until_filters_future_rows_before_list_offset_and_search_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "INSERT INTO sessions(id, provider, session_id, harness, title, created_at, last_active_at, source_path) \
             VALUES(4, 'codex', 'future', 'Codex', 'future boundedneedle', 2000000000, 2000000000, '/Users/example/future.jsonl'); \
             INSERT INTO session_messages(id, session_row, seq, role, excerpt) VALUES \
               (16, 1, 2, 'user', 'shared boundedneedle text'), \
               (17, 2, 1, 'user', 'shared boundedneedle text'), \
               (18, 4, 0, 'user', 'shared boundedneedle text');",
        )
        .unwrap();
        drop(conn);

        let reader = SessionIndexReader::open(&path).unwrap();
        let page = reader
            .list(&SessionListFilter {
                until: Some(1_700_002_000),
                offset: 1,
                limit: 1,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].provider, SessionProvider::Codex);

        let hits = reader
            .search(
                "boundedneedle",
                &SessionListFilter {
                    until: Some(1_700_002_000),
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert!(hits.iter().all(|hit| hit.session.session_id != "future"));
    }

    #[test]
    fn caps_distinct_filter_values_and_deduplicates_repeats() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let repeats = reader
            .list(&SessionListFilter {
                providers: Some(vec![SessionProvider::Codex; MAX_FILTER_VALUES + 1]),
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(repeats.len(), 1);

        let error = reader
            .list(&SessionListFilter {
                harnesses: Some(
                    (0..=MAX_FILTER_VALUES)
                        .map(|index| format!("Harness {index}"))
                        .collect(),
                ),
                limit: 10,
                ..Default::default()
            })
            .unwrap_err();
        assert!(matches!(
            error,
            SessionCoreError::FilterTooLarge {
                field: "harnesses",
                max: MAX_FILTER_VALUES,
            }
        ));
    }

    #[test]
    fn fts_and_like_search() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let hits = reader
            .search(
                "tray",
                &SessionListFilter {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].session.provider, SessionProvider::Codex);
        // Two-char needle → LIKE path.
        let like_hits = reader
            .search(
                "sq",
                &SessionListFilter {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(like_hits.len(), 1);
        assert_eq!(like_hits[0].session.provider, SessionProvider::Claude);

        // Metadata matches are visible even when no excerpt matches.
        let title_only = reader
            .search(
                "bbbb2222",
                &SessionListFilter {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(title_only.len(), 1);
        assert_eq!(title_only[0].session.provider, SessionProvider::Claude);
        assert_eq!(title_only[0].seq, None);
    }

    #[test]
    fn scoped_search_defaults_to_title_user_assistant_and_filters_projects() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "INSERT INTO session_messages(id, session_row, seq, role, excerpt) VALUES \
             (13, 1, 2, 'system', 'system-only needle'), \
             (14, 1, 3, 'tool', 'tool-only needle'), \
             (15, 2, 1, 'assistant', 'assistant project needle');",
        )
        .unwrap();
        drop(conn);
        let reader = SessionIndexReader::open(&path).unwrap();

        // The default scope intentionally does not surface system or tool.
        assert!(reader
            .search_with_filter("system-only", &SessionSearchFilter::default())
            .unwrap()
            .is_empty());
        let system = reader
            .search_with_filter(
                "system-only",
                &SessionSearchFilter {
                    scopes: [SessionSearchScope::System].into_iter().collect(),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(
            system[0].session.session_id,
            "aaaa1111-0000-0000-0000-000000000001"
        );
        let tool = reader
            .search_with_filter(
                "tool-only",
                &SessionSearchFilter {
                    scopes: [SessionSearchScope::Tool].into_iter().collect(),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(tool[0].seq, Some(3));

        // Title/session-id metadata joins only with Title, and projects narrow
        // both metadata and transcript branches without becoming searchable.
        let title_only = reader
            .search_with_filter(
                "bbbb2222",
                &SessionSearchFilter {
                    scopes: [SessionSearchScope::Title].into_iter().collect(),
                    project_includes: vec!["proj2".to_string()],
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(title_only[0].seq, None);
        assert!(reader
            .search_with_filter(
                "assistant project",
                &SessionSearchFilter {
                    project_excludes: vec!["proj2".to_string()],
                    ..Default::default()
                },
            )
            .unwrap()
            .is_empty());
    }

    #[test]
    fn legacy_search_preserves_since_for_fts_like_and_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        let after_every_fixture = 1_800_000_000;

        for needle in ["tray", "sq", "bbbb2222"] {
            let hits = reader
                .search(
                    needle,
                    &SessionListFilter {
                        since: Some(after_every_fixture),
                        limit: 10,
                        ..Default::default()
                    },
                )
                .unwrap();
            assert!(hits.is_empty(), "since was ignored for {needle:?}");
        }
    }

    #[test]
    fn body_search_deduplicates_before_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "INSERT INTO sessions(id, provider, session_id, harness, title, created_at, source_path) \
             VALUES(4, 'codex', 'dddd', 'Codex', 'second tray', 1700004000, '/d.jsonl'); \
             INSERT INTO session_messages(id, session_row, seq, role, excerpt) \
             VALUES(13, 4, 0, 'user', 'another tray result');",
        )
        .unwrap();
        drop(conn);
        let reader = SessionIndexReader::open(&path).unwrap();
        let hits = reader
            .search(
                "tray",
                &SessionListFilter {
                    limit: 2,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert_ne!(hits[0].session.row_id, hits[1].session.row_id);
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

    #[test]
    fn clamps_query_sizes_before_sqlite_binding() {
        assert_eq!(
            SessionIndexReader::bounded_limit(usize::MAX),
            MAX_QUERY_LIMIT as i64
        );
        assert_eq!(
            SessionIndexReader::bounded_offset(usize::MAX),
            MAX_QUERY_OFFSET as i64
        );
        assert_eq!(
            SessionIndexReader::bounded_search_limit(MAX_QUERY_LIMIT as i64, false),
            MAX_LIKE_SEARCH_LIMIT as i64
        );

        let dir = tempfile::tempdir().unwrap();
        let path = fixture_index(dir.path());
        let reader = SessionIndexReader::open(&path).unwrap();
        assert!(reader
            .list(&SessionListFilter {
                limit: usize::MAX,
                offset: usize::MAX,
                ..Default::default()
            })
            .unwrap()
            .is_empty());
        assert!(
            reader
                .search(
                    "tray",
                    &SessionListFilter {
                        limit: usize::MAX,
                        ..Default::default()
                    }
                )
                .unwrap()
                .len()
                <= MAX_QUERY_LIMIT
        );
        assert!(reader
            .excerpts(1, usize::MAX, usize::MAX)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn opaque_reference_resolves_transcript_without_caller_path() {
        let dir = tempfile::tempdir().unwrap();
        let transcript_path = dir.path().join("session.jsonl");
        std::fs::write(
            &transcript_path,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"hello\"}]}}\n",
        )
        .unwrap();
        let path = fixture_index(dir.path());
        let conn = Connection::open(&path).unwrap();
        conn.execute(
            "UPDATE sessions SET source_path = ? WHERE id = 1",
            [transcript_path.to_string_lossy().into_owned()],
        )
        .unwrap();
        drop(conn);

        let reader = SessionIndexReader::open(&path).unwrap();
        let page = reader.read_transcript_page(SessionRef(1), 0, 10).unwrap();
        assert_eq!(page.messages[0].text, "hello");
        assert!(matches!(
            reader.read_transcript_page(SessionRef(99), 0, 1),
            Err(SessionCoreError::SessionNotFound(99))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_index() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let target = fixture_index(dir.path());
        let link = dir.path().join("index-link.sqlite3");
        symlink(target, &link).unwrap();
        assert!(matches!(
            SessionIndexReader::open(&link),
            Err(SessionCoreError::UnsafePath(_))
        ));
    }
}
