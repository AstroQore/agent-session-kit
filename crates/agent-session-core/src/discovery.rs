//! Lightweight filesystem discovery for Codex and Claude Code sessions.
//!
//! This is the standalone fallback for a host that has no shared session
//! index yet: it enumerates session files with their metadata cheaply (head
//! lines only, never whole files) so a UI can render a recent-sessions list.
//! Full indexing (FTS, every harness) stays with the index writer.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::Serialize;

use crate::jsonl;
use crate::provider::SessionProvider;

#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredSession {
    pub provider: SessionProvider,
    pub session_id: String,
    pub title: Option<String>,
    pub project_dir: Option<String>,
    /// Internal source location. It is metadata, not an authorization token:
    /// hosts must resolve a selected session in their trusted backend.
    pub source_path: String,
    /// Unix epoch seconds of the file's last modification.
    pub modified_at: i64,
    pub size_bytes: u64,
}

/// Enumerate Codex sessions under `<home>/.codex/sessions` (and
/// `archived_sessions`), newest first, capped at `limit`.
pub fn discover_codex(home: &Path, limit: usize) -> Vec<DiscoveredSession> {
    let mut files: Vec<(PathBuf, i64, u64)> = Vec::new();
    collect_jsonl_files(&home.join(".codex/sessions"), &mut files, 4);
    collect_jsonl_files(&home.join(".codex/archived_sessions"), &mut files, 4);
    files.sort_by_key(|f| std::cmp::Reverse(f.1));
    files.truncate(limit);

    files
        .into_iter()
        .filter_map(|(path, mtime, size)| {
            let head = jsonl::head_json_lines(&path, 8).ok()?;
            let mut session_id = None;
            let mut cwd = None;
            let mut title = None;
            for line in &head {
                let line_type = line.get("type").and_then(|v| v.as_str());
                if line_type == Some("session_meta") {
                    let payload = line.get("payload")?;
                    if session_id.is_none() {
                        session_id = payload
                            .get("id")
                            .and_then(|v| v.as_str())
                            .map(str::to_string);
                    }
                    if cwd.is_none() {
                        cwd = payload
                            .get("cwd")
                            .and_then(|v| v.as_str())
                            .map(str::to_string);
                    }
                } else if line_type == Some("response_item") && title.is_none() {
                    let payload = line.get("payload")?;
                    if payload.get("type").and_then(|v| v.as_str()) == Some("message")
                        && payload.get("role").and_then(|v| v.as_str()) == Some("user")
                    {
                        title = first_text(payload.get("content")).map(|t| truncate_title(&t));
                    }
                }
            }
            // Fall back to the rollout filename's trailing uuid when the meta
            // line is missing.
            let session_id = session_id.or_else(|| session_id_from_rollout_name(&path))?;
            Some(DiscoveredSession {
                provider: SessionProvider::Codex,
                session_id,
                title,
                project_dir: cwd,
                source_path: path.to_string_lossy().into_owned(),
                modified_at: mtime,
                size_bytes: size,
            })
        })
        .collect()
}

/// Enumerate Claude Code sessions under `<home>/.claude/projects` and
/// `<home>/.config/claude/projects`, newest first, capped at `limit`.
pub fn discover_claude(home: &Path, limit: usize) -> Vec<DiscoveredSession> {
    let mut files: Vec<(PathBuf, i64, u64)> = Vec::new();
    collect_jsonl_files(&home.join(".claude/projects"), &mut files, 3);
    collect_jsonl_files(&home.join(".config/claude/projects"), &mut files, 3);
    files.sort_by_key(|f| std::cmp::Reverse(f.1));
    files.truncate(limit);

    files
        .into_iter()
        .filter_map(|(path, mtime, size)| {
            let stem = path.file_stem()?.to_string_lossy().into_owned();
            if !looks_like_uuid(&stem) {
                return None;
            }
            let head = jsonl::head_json_lines(&path, 12).ok().unwrap_or_default();
            let mut cwd = None;
            let mut title = None;
            for line in &head {
                if cwd.is_none() {
                    cwd = line.get("cwd").and_then(|v| v.as_str()).map(str::to_string);
                }
                if title.is_none() && line.get("type").and_then(|v| v.as_str()) == Some("user") {
                    let text = line
                        .get("message")
                        .and_then(|m| m.get("content"))
                        .and_then(message_content_text);
                    if let Some(text) = text {
                        title = Some(truncate_title(&text));
                    }
                }
                if cwd.is_some() && title.is_some() {
                    break;
                }
            }
            Some(DiscoveredSession {
                provider: SessionProvider::Claude,
                session_id: stem,
                title,
                project_dir: cwd,
                source_path: path.to_string_lossy().into_owned(),
                modified_at: mtime,
                size_bytes: size,
            })
        })
        .collect()
}

fn collect_jsonl_files(root: &Path, out: &mut Vec<(PathBuf, i64, u64)>, max_depth: usize) {
    if max_depth == 0 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        // Never follow symlinks while walking someone else's log tree.
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            collect_jsonl_files(&path, out, max_depth - 1);
        } else if path.extension().is_some_and(|e| e == "jsonl") {
            let Ok(meta) = entry.metadata() else { continue };
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            out.push((path, mtime, meta.len()));
        }
    }
}

/// `rollout-2026-08-30T04-55-08-<uuid>.jsonl` → the trailing uuid.
fn session_id_from_rollout_name(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_string_lossy();
    let candidate = stem.rsplit('-').next()?; // last dash-separated chunk
                                              // The uuid itself contains dashes, so take the last 36 chars instead.
    let chars: Vec<char> = stem.chars().collect();
    if chars.len() >= 36 {
        let tail: String = chars[chars.len() - 36..].iter().collect();
        if looks_like_uuid(&tail) {
            return Some(tail);
        }
    }
    if looks_like_uuid(candidate) {
        return Some(candidate.to_string());
    }
    None
}

fn looks_like_uuid(value: &str) -> bool {
    value.len() == 36
        && value.chars().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

fn first_text(content: Option<&serde_json::Value>) -> Option<String> {
    let array = content?.as_array()?;
    for block in array {
        if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

/// Claude `message.content` is either a plain string or an array of blocks.
fn message_content_text(content: &serde_json::Value) -> Option<String> {
    if let Some(text) = content.as_str() {
        let trimmed = text.trim();
        return (!trimmed.is_empty()).then(|| trimmed.to_string());
    }
    first_text(Some(content))
}

fn truncate_title(text: &str) -> String {
    let single_line = text.lines().next().unwrap_or("").trim();
    let mut out: String = single_line.chars().take(120).collect();
    if single_line.chars().count() > 120 {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn discovers_codex_and_claude_fixtures() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();

        let codex_dir = home.join(".codex/sessions/2026/08/30");
        std::fs::create_dir_all(&codex_dir).unwrap();
        let codex_file = codex_dir
            .join("rollout-2026-08-30T04-55-08-0199aaaa-1111-2222-3333-444455556666.jsonl");
        let mut f = std::fs::File::create(&codex_file).unwrap();
        writeln!(f, "{}", serde_json::json!({
            "type": "session_meta", "timestamp": "2026-08-30T04:55:08Z",
            "payload": {"id": "0199aaaa-1111-2222-3333-444455556666", "cwd": "/Users/example/proj"}
        })).unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "response_item", "timestamp": "2026-08-30T04:55:09Z",
                "payload": {"type": "message", "role": "user",
                            "content": [{"type": "input_text", "text": "fix the tray bug"}]}
            })
        )
        .unwrap();
        drop(f);

        let claude_dir = home.join(".claude/projects/-Users-example-proj");
        std::fs::create_dir_all(&claude_dir).unwrap();
        let claude_file = claude_dir.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl");
        let mut f = std::fs::File::create(&claude_file).unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "user", "cwd": "/Users/example/proj", "timestamp": "2026-08-30T05:00:00Z",
                "message": {"role": "user", "content": "refactor storage"}
            })
        )
        .unwrap();
        drop(f);

        let codex = discover_codex(home, 10);
        assert_eq!(codex.len(), 1);
        assert_eq!(codex[0].session_id, "0199aaaa-1111-2222-3333-444455556666");
        assert_eq!(codex[0].title.as_deref(), Some("fix the tray bug"));
        assert_eq!(codex[0].project_dir.as_deref(), Some("/Users/example/proj"));

        let claude = discover_claude(home, 10);
        assert_eq!(claude.len(), 1);
        assert_eq!(claude[0].session_id, "aaaabbbb-cccc-dddd-eeee-ffff00001111");
        assert_eq!(claude[0].title.as_deref(), Some("refactor storage"));
    }
}
