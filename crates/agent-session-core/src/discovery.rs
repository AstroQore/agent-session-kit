//! Lightweight filesystem discovery for Codex and Claude Code sessions.
//!
//! This is the standalone fallback for a host that has no shared session
//! index yet: it enumerates session files with their metadata cheaply (head
//! lines plus a bounded tail, never whole files) so a UI can render a recent-
//! sessions list.
//! Full indexing (FTS, every harness) stays with the index writer.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::jsonl;
use crate::provider::SessionProvider;

#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredSession {
    pub provider: SessionProvider,
    /// Raw harness key when discovery can distinguish the producing surface.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    pub session_id: String,
    /// Provider-specific relationship metadata, matching the shared index.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_variant: Option<String>,
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
    let mut files: Vec<(PathBuf, SystemTime, u64)> = Vec::new();
    if let Some(root) = safe_root(home, &[".codex", "sessions"]) {
        collect_jsonl_files(&root, &mut files, 4);
    }
    if let Some(root) = safe_root(home, &[".codex", "archived_sessions"]) {
        collect_jsonl_files(&root, &mut files, 4);
    }
    sort_files(&mut files);

    files
        .into_iter()
        .filter_map(|(path, mtime, size)| {
            let head = jsonl::head_json_lines(&path, 10).ok().unwrap_or_default();
            let tail = jsonl::tail_json_lines(&path, jsonl::MAX_TAIL_BYTES)
                .ok()
                .unwrap_or_default();
            if head.is_empty() && tail.is_empty() {
                return None;
            }
            let mut session_id = None;
            let mut cwd = None;
            let mut title = None;
            for line in &head {
                let line_type = line.get("type").and_then(|v| v.as_str());
                if line_type == Some("session_meta") {
                    if let Some(payload) = line.get("payload") {
                        if session_id.is_none() {
                            session_id = nonempty_json_string(payload.get("id"))
                                .or_else(|| nonempty_json_string(payload.get("thread_id")));
                        }
                        if cwd.is_none() {
                            cwd = nonempty_json_string(payload.get("cwd"));
                        }
                    }
                } else if line_type == Some("response_item") && title.is_none() {
                    if let Some(payload) = line.get("payload") {
                        if payload.get("type").and_then(|v| v.as_str()) == Some("message")
                            && payload.get("role").and_then(|v| v.as_str()) == Some("user")
                        {
                            title = payload
                                .get("content")
                                .and_then(message_content_text)
                                .map(|text| strip_codex_ide_envelope(&text))
                                .and_then(|text| human_title_text(&text))
                                .map(|text| truncate_title(&text));
                        }
                    }
                }
            }
            let filename_id = session_id_from_rollout_name(&path);
            // Older Codex headers call the resume id `thread_id`; the tail
            // is also a bounded fallback for metadata pushed beyond the head
            // window by a newer writer.
            if session_id.is_none() || cwd.is_none() {
                for line in head.iter().chain(tail.iter()) {
                    if line.get("type").and_then(|value| value.as_str()) != Some("session_meta") {
                        continue;
                    }
                    let Some(payload) = line.get("payload") else {
                        continue;
                    };
                    if session_id.is_none() {
                        session_id = nonempty_json_string(payload.get("id"))
                            .or_else(|| nonempty_json_string(payload.get("thread_id")));
                    }
                    if cwd.is_none() {
                        cwd = nonempty_json_string(payload.get("cwd"));
                    }
                    if session_id.is_some() && cwd.is_some() {
                        break;
                    }
                }
            }
            // Fall back to the rollout filename's trailing uuid when the
            // session meta line is missing.
            let (session_id, session_id_from_filename) = match session_id {
                Some(session_id) => (session_id, false),
                None => (filename_id.clone()?, true),
            };
            if filename_id
                .as_deref()
                .is_some_and(|filename_id| !session_id.eq_ignore_ascii_case(filename_id))
            {
                return None;
            }
            let owned_meta =
                codex_session_meta(&head, &tail, &session_id, session_id_from_filename);
            let provider_variant =
                owned_meta.and_then(|meta| codex_auto_review_provider_variant(meta, &head, &tail));
            let harness = owned_meta
                .and_then(|payload| payload.get("originator"))
                .and_then(|value| value.as_str())
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map_or("codex", |originator| {
                    if originator == "codex_work_desktop" {
                        "chatgptWork"
                    } else {
                        "codex"
                    }
                });
            Some(DiscoveredSession {
                provider: SessionProvider::Codex,
                harness: Some(harness.to_string()),
                session_id,
                provider_variant,
                title,
                project_dir: cwd,
                source_path: path.to_string_lossy().into_owned(),
                modified_at: unix_seconds(mtime),
                size_bytes: size,
            })
        })
        .take(limit)
        .collect()
}

/// Enumerate Claude Code sessions under `<home>/.claude/projects` and
/// `<home>/.config/claude/projects`, newest first, capped at `limit`.
pub fn discover_claude(home: &Path, limit: usize) -> Vec<DiscoveredSession> {
    let mut files: Vec<(PathBuf, SystemTime, u64)> = Vec::new();
    if let Some(root) = safe_root(home, &[".claude", "projects"]) {
        collect_jsonl_files(&root, &mut files, 3);
    }
    if let Some(root) = safe_root(home, &[".config", "claude", "projects"]) {
        collect_jsonl_files(&root, &mut files, 3);
    }
    sort_files(&mut files);

    files
        .into_iter()
        .filter_map(|(path, mtime, size)| {
            let stem = path.file_stem()?.to_string_lossy().into_owned();
            if stem.starts_with("agent-") {
                return None;
            }
            let head = jsonl::head_json_lines(&path, 12).ok().unwrap_or_default();
            let tail = jsonl::tail_json_lines(&path, jsonl::MAX_TAIL_BYTES)
                .ok()
                .unwrap_or_default();
            if head.is_empty() && tail.is_empty() {
                return None;
            }
            let session_id = if looks_like_uuid(&stem) {
                stem.clone()
            } else {
                tail.iter()
                    .rev()
                    .find_map(|line| nonempty_json_string(line.get("sessionId")))
                    .or_else(|| {
                        head.iter()
                            .find_map(|line| nonempty_json_string(line.get("sessionId")))
                    })
                    .unwrap_or_else(|| stem.clone())
            };
            let mut cwd = None;
            let mut title = None;
            for line in tail.iter().rev() {
                if line.get("type").and_then(|v| v.as_str()) == Some("custom-title") {
                    if let Some(value) = line.get("customTitle").and_then(|v| v.as_str()) {
                        let value = value.trim();
                        if !value.is_empty() {
                            title = Some(truncate_title(value));
                            break;
                        }
                    }
                }
            }
            for line in &head {
                if cwd.is_none() {
                    cwd = nonempty_json_string(line.get("cwd"));
                }
                if line.get("isMeta").and_then(|value| value.as_bool()) == Some(true) {
                    continue;
                }
                if title.is_none() && line.get("type").and_then(|v| v.as_str()) == Some("user") {
                    let text = line
                        .get("message")
                        .and_then(|m| m.get("content"))
                        .and_then(message_content_text);
                    if let Some(text) = text.and_then(|text| human_title_text(&text)) {
                        if !is_claude_envelope_text(&text) {
                            title = Some(truncate_title(&text));
                        }
                    }
                }
                if cwd.is_some() && title.is_some() {
                    break;
                }
            }
            if cwd.is_none() {
                cwd = tail
                    .iter()
                    .rev()
                    .find_map(|line| nonempty_json_string(line.get("cwd")));
            }
            if title.is_none() {
                title = cwd
                    .as_deref()
                    .and_then(project_basename)
                    .map(truncate_title);
            }
            Some(DiscoveredSession {
                provider: SessionProvider::Claude,
                harness: Some("claudeCode".to_string()),
                session_id,
                provider_variant: None,
                title,
                project_dir: cwd,
                source_path: path.to_string_lossy().into_owned(),
                modified_at: unix_seconds(mtime),
                size_bytes: size,
            })
        })
        .take(limit)
        .collect()
}

/// Builds a discovery root only when every provider-owned component is a real
/// directory. This prevents a configured root or an intermediate component
/// from redirecting the walk through a symlink. Like other std-only checks it
/// remains best-effort against a same-user replacement race after checking.
fn safe_root(home: &Path, components: &[&str]) -> Option<PathBuf> {
    let mut path = home.to_path_buf();
    for component in components {
        path.push(component);
        let metadata = std::fs::symlink_metadata(&path).ok()?;
        if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
            return None;
        }
    }
    Some(path)
}

fn collect_jsonl_files(root: &Path, out: &mut Vec<(PathBuf, SystemTime, u64)>, max_depth: usize) {
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
        } else if file_type.is_file() && path.extension().is_some_and(|e| e == "jsonl") {
            let Ok(meta) = entry.metadata() else { continue };
            let mtime = meta.modified().unwrap_or(UNIX_EPOCH);
            out.push((path, mtime, meta.len()));
        }
    }
}

/// A deterministic source-path tiebreak keeps discovery order stable when
/// multiple files have the same filesystem timestamp.
fn sort_files(files: &mut [(PathBuf, SystemTime, u64)]) {
    files.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
}

fn unix_seconds(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64)
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

fn nonempty_json_string(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn codex_auto_review_provider_variant(
    meta: &serde_json::Value,
    head: &[serde_json::Value],
    tail: &[serde_json::Value],
) -> Option<String> {
    let source = meta.get("source");
    let is_guardian = json_string_is(
        source
            .and_then(|value| value.get("subagent"))
            .and_then(|value| value.get("other")),
        "guardian",
    );
    let model = codex_model(head).or_else(|| codex_model(tail));
    let is_review_runtime = json_string_is(meta.get("thread_source"), "subagent")
        && model
            .as_deref()
            .is_some_and(|model| model.eq_ignore_ascii_case("codex-auto-review"));
    if !is_guardian && !is_review_runtime {
        return None;
    }
    let root_id = nonempty_json_string(meta.get("session_id"))
        .or_else(|| nonempty_json_string(meta.get("parent_thread_id")))?;
    Some(format!("auto-review:{root_id}"))
}

fn codex_session_meta<'a>(
    head: &'a [serde_json::Value],
    tail: &'a [serde_json::Value],
    session_id: &str,
    session_id_from_filename: bool,
) -> Option<&'a serde_json::Value> {
    let mut idless_meta = None;
    let mut saw_nonempty_id = false;
    for line in head.iter().chain(tail.iter()) {
        let payload = (line.get("type").and_then(|value| value.as_str()) == Some("session_meta"))
            .then(|| line.get("payload"))
            .flatten();
        let Some(payload) = payload else {
            continue;
        };
        let mut has_nonempty_id = false;
        for candidate in [payload.get("id"), payload.get("thread_id")]
            .into_iter()
            .flatten()
            .filter_map(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            has_nonempty_id = true;
            saw_nonempty_id = true;
            if candidate.eq_ignore_ascii_case(session_id) {
                return Some(payload);
            }
        }
        if !has_nonempty_id && idless_meta.is_none() {
            idless_meta = Some(payload);
        }
    }
    if session_id_from_filename && !saw_nonempty_id {
        idless_meta
    } else {
        None
    }
}

fn codex_model(lines: &[serde_json::Value]) -> Option<String> {
    lines.iter().find_map(|line| {
        let payload = line.get("payload");
        let info = payload.and_then(|value| value.get("info"));
        nonempty_json_string(payload.and_then(|value| value.get("model")))
            .or_else(|| nonempty_json_string(info.and_then(|value| value.get("model"))))
            .or_else(|| nonempty_json_string(info.and_then(|value| value.get("model_name"))))
            .or_else(|| nonempty_json_string(line.get("model")))
    })
}

fn json_string_is(value: Option<&serde_json::Value>, expected: &str) -> bool {
    value
        .and_then(|value| value.as_str())
        .map(str::trim)
        .is_some_and(|value| value.eq_ignore_ascii_case(expected))
}

/// Flatten the same bounded display shapes the Swift adapters accept for a
/// discovery title. Arrays join every renderable block instead of silently
/// taking only the first one.
fn message_content_text(content: &serde_json::Value) -> Option<String> {
    message_content_text_at_depth(content, 0)
}

fn message_content_text_at_depth(content: &serde_json::Value, depth: usize) -> Option<String> {
    if depth >= 8 {
        return None;
    }
    if let Some(text) = content.as_str() {
        let trimmed = text.trim();
        return (!trimmed.is_empty()).then(|| trimmed.to_string());
    }
    if let Some(array) = content.as_array() {
        let parts: Vec<_> = array
            .iter()
            .filter_map(|value| message_content_text_at_depth(value, depth + 1))
            .collect();
        return (!parts.is_empty()).then(|| parts.join("\n"));
    }
    match content.get("type").and_then(|value| value.as_str()) {
        Some("tool_use") => {
            let name = content
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or("tool");
            let input = content
                .get("input")
                .filter(|value| !value.is_null())
                .map(|value| value.to_string());
            return Some(match input {
                Some(input) if !input.is_empty() && input != "{}" => {
                    format!("[Tool: {name}]\n{input}")
                }
                _ => format!("[Tool: {name}]"),
            });
        }
        Some("tool_result") => {
            return content
                .get("content")
                .and_then(|value| message_content_text_at_depth(value, depth + 1));
        }
        Some("thinking") => return None,
        _ => {}
    }
    ["text", "input_text", "output_text", "content"]
        .iter()
        .find_map(|key| {
            content
                .get(*key)
                .and_then(|value| message_content_text_at_depth(value, depth + 1))
        })
}

fn truncate_title(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = collapsed.chars().take(80).collect();
    if collapsed.chars().count() > 80 {
        out.push('…');
    }
    out
}

fn project_basename(project_dir: &str) -> Option<&str> {
    project_dir
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .filter(|name| !name.is_empty())
}

fn human_title_text(text: &str) -> Option<String> {
    let mut body = String::with_capacity(text.len());
    let mut cursor = 0;
    while let Some((start, open_end, name)) = first_machine_context_opening(text, cursor) {
        body.push_str(&text[cursor..start]);
        let close_end = tags_from(text, open_end)
            .find(|(_, _, candidate, closing)| *closing && candidate == &name)
            .map(|(_, close_end, _, _)| close_end);
        if let Some(close_end) = close_end {
            cursor = close_end;
        } else {
            cursor = text.len();
            break;
        }
    }
    body.push_str(&text[cursor..]);
    let body = strip_boilerplate_lines(&body);
    let body = body.trim();
    (!body.is_empty()).then(|| body.to_string())
}

fn strip_boilerplate_lines(text: &str) -> String {
    text.split('\n')
        .filter(|line| {
            let normalized = line.trim().to_ascii_lowercase();
            !(normalized.starts_with('#') && normalized.contains("agents.md instructions"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn first_machine_context_opening(text: &str, cursor: usize) -> Option<(usize, usize, String)> {
    tags_from(text, cursor).find_map(|(start, end, name, closing)| {
        (!closing && is_machine_context_tag(&name)).then_some((start, end, name))
    })
}

fn tags_from(
    text: &str,
    mut cursor: usize,
) -> impl Iterator<Item = (usize, usize, String, bool)> + '_ {
    std::iter::from_fn(move || {
        let start = cursor + text[cursor..].find('<')?;
        let end = start + text[start..].find('>')? + 1;
        cursor = end;
        let mut inner = text[start + 1..end - 1].trim_start();
        let closing = inner.starts_with('/');
        if closing {
            inner = inner[1..].trim_start();
        }
        let name = inner
            .chars()
            .take_while(|character| !character.is_whitespace() && *character != '/')
            .collect::<String>()
            .to_ascii_lowercase();
        Some((start, end, name, closing))
    })
}

fn is_machine_context_tag(name: &str) -> bool {
    matches!(
        name,
        "command-name"
            | "command-message"
            | "command-args"
            | "command-contents"
            | "system-reminder"
            | "user-prompt-submit-hook"
            | "environment_context"
            | "user_instructions"
            | "app-context"
            | "recommended_plugins"
            | "skills_instructions"
            | "permissions"
            | "collaboration_mode"
            | "apps_instructions"
            | "plugins_instructions"
            | "instructions"
            | "task-notification"
            | "task-id"
            | "tool-use-id"
            | "output-file"
            | "status"
            | "summary"
            | "result"
            | "note"
            | "cross-session-message"
    ) || name.starts_with("local-command-")
}

fn is_claude_envelope_text(text: &str) -> bool {
    [
        "<command-name>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "Caveat: The messages below were generated by the user while running local commands",
    ]
    .iter()
    .any(|marker| text.contains(marker))
}

fn strip_codex_ide_envelope(text: &str) -> String {
    const CONTEXT: &str = "# Context from my IDE setup:";
    const REQUEST: &str = "## My request for Codex:";
    if text.contains(CONTEXT) {
        if let Some((_, request)) = text.split_once(REQUEST) {
            return request.trim().to_string();
        }
    }
    text.to_string()
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
        assert_eq!(codex[0].harness.as_deref(), Some("codex"));
        assert_eq!(codex[0].title.as_deref(), Some("fix the tray bug"));
        assert_eq!(codex[0].project_dir.as_deref(), Some("/Users/example/proj"));

        let claude = discover_claude(home, 10);
        assert_eq!(claude.len(), 1);
        assert_eq!(claude[0].session_id, "aaaabbbb-cccc-dddd-eeee-ffff00001111");
        assert_eq!(claude[0].harness.as_deref(), Some("claudeCode"));
        assert_eq!(claude[0].title.as_deref(), Some("refactor storage"));
    }

    #[test]
    fn codex_bad_metadata_records_do_not_hide_filename_session() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let path = sessions.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"session_meta\"}\n{\"type\":\"response_item\"}\n",
        )
        .unwrap();

        let sessions = discover_codex(dir.path(), 10);
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0].session_id,
            "0199aaaa-1111-2222-3333-444455556666"
        );
    }

    #[test]
    fn blank_codex_metadata_ids_fall_back_to_filename_uuid() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        std::fs::write(
            sessions.join("rollout-a-0199aaaa-1111-2222-3333-444455556666.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"   \"}}\n",
        )
        .unwrap();
        std::fs::write(
            sessions.join("rollout-b-0199bbbb-1111-2222-3333-444455556666.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"thread_id\":\" \\t \"}}\n",
        )
        .unwrap();
        let mut ids = discover_codex(dir.path(), 10)
            .into_iter()
            .map(|session| session.session_id)
            .collect::<Vec<_>>();
        ids.sort();
        assert_eq!(
            ids,
            [
                "0199aaaa-1111-2222-3333-444455556666",
                "0199bbbb-1111-2222-3333-444455556666",
            ]
        );
    }

    #[test]
    fn codex_work_originator_sets_chatgpt_work_harness() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        std::fs::write(
            sessions.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\",\"originator\":\"codex_work_desktop\"}}\n",
        )
        .unwrap();
        let session = discover_codex(dir.path(), 1).remove(0);
        assert_eq!(session.harness.as_deref(), Some("chatgptWork"));
        assert!(session.provider_variant.is_none());
        assert!(serde_json::to_value(session)
            .unwrap()
            .get("provider_variant")
            .is_none());
    }

    #[test]
    fn codex_filename_identity_owns_only_entirely_idless_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let session_id = "0199aaaa-1111-2222-3333-444455556668";
        let root_id = "0299aaaa-1111-2222-3333-444455556668";
        std::fs::write(
            sessions.join(format!("rollout-x-{session_id}.jsonl")),
            serde_json::json!({
                "type": "session_meta",
                "payload": {
                    "session_id": root_id,
                    "originator": "codex_work_desktop",
                    "source": {"subagent": {"other": "guardian"}}
                }
            })
            .to_string(),
        )
        .unwrap();

        let session = discover_codex(dir.path(), 1).remove(0);
        assert_eq!(session.session_id, session_id);
        assert_eq!(session.harness.as_deref(), Some("chatgptWork"));
        assert_eq!(
            session.provider_variant.as_deref(),
            Some("auto-review:0299aaaa-1111-2222-3333-444455556668")
        );

        let mut candidate_headers = vec![
            serde_json::json!({
                "type": "session_meta",
                "payload": {"originator": "codex_work_desktop"}
            }),
            serde_json::json!({
                "type": "session_meta",
                "payload": {"id": "0399aaaa-1111-2222-3333-444455556668"}
            }),
        ];
        assert!(codex_session_meta(&candidate_headers, &[], session_id, true).is_none());

        candidate_headers.push(serde_json::json!({
            "type": "session_meta",
            "payload": {"thread_id": session_id, "originator": "codex_cli_rs"}
        }));
        assert_eq!(
            codex_session_meta(&candidate_headers, &[], session_id, true)
                .and_then(|meta| meta.get("originator"))
                .and_then(|value| value.as_str()),
            Some("codex_cli_rs")
        );
    }

    #[test]
    fn codex_auto_review_relationship_matches_guardian_and_runtime_markers() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let guardian_id = "0199aaaa-1111-2222-3333-444455556601";
        let guardian_root = "0299aaaa-1111-2222-3333-444455556601";
        let runtime_id = "0199aaaa-1111-2222-3333-444455556602";
        let runtime_root = "0299aaaa-1111-2222-3333-444455556602";
        let normal_id = "0199aaaa-1111-2222-3333-444455556603";
        let replay_id = "0199aaaa-1111-2222-3333-444455556604";

        let write = |id: &str, lines: &[serde_json::Value]| {
            let path = sessions.join(format!("rollout-x-{id}.jsonl"));
            let mut file = std::io::BufWriter::new(std::fs::File::create(path).unwrap());
            for line in lines {
                writeln!(file, "{line}").unwrap();
            }
        };
        write(
            guardian_id,
            &[serde_json::json!({
                "type": "session_meta",
                "payload": {
                    "id": guardian_id,
                    "session_id": guardian_root,
                    "parent_thread_id": "0399aaaa-1111-2222-3333-444455556601",
                    "originator": "Codex Desktop",
                    "source": {"subagent": {"other": " Guardian "}}
                }
            })],
        );
        write(
            runtime_id,
            &[
                serde_json::json!({
                    "type": "session_meta",
                    "payload": {
                        "id": runtime_id,
                        "parent_thread_id": runtime_root,
                        "originator": "codex_work_desktop",
                        "thread_source": " SUBAGENT ",
                        "source": "cli"
                    }
                }),
                serde_json::json!({
                    "type": "turn_context",
                    "payload": {"model": " Codex-Auto-Review "}
                }),
            ],
        );
        write(
            normal_id,
            &[
                serde_json::json!({
                    "type": "session_meta",
                    "payload": {
                        "id": normal_id,
                        "session_id": "0299aaaa-1111-2222-3333-444455556603",
                        "originator": "codex_cli_rs",
                        "thread_source": "subagent",
                        "source": {"subagent": {"other": "worker"}}
                    }
                }),
                serde_json::json!({
                    "type": "turn_context",
                    "payload": {"model": "gpt-5"}
                }),
            ],
        );
        write(
            replay_id,
            &[
                serde_json::json!({
                    "type": "session_meta",
                    "payload": {
                        "session_id": "0299aaaa-1111-2222-3333-444455556604",
                        "originator": "codex_work_desktop",
                        "source": {"subagent": {"other": "guardian"}}
                    }
                }),
                serde_json::json!({
                    "type": "session_meta",
                    "payload": {"id": replay_id, "originator": "codex_cli_rs"}
                }),
            ],
        );

        let sessions = discover_codex(dir.path(), 10)
            .into_iter()
            .map(|session| (session.session_id.clone(), session))
            .collect::<std::collections::HashMap<_, _>>();
        let guardian = &sessions[guardian_id];
        assert_eq!(
            guardian.provider_variant.as_deref(),
            Some("auto-review:0299aaaa-1111-2222-3333-444455556601")
        );
        assert_eq!(guardian.harness.as_deref(), Some("codex"));
        assert_eq!(
            serde_json::to_value(guardian).unwrap()["provider_variant"],
            "auto-review:0299aaaa-1111-2222-3333-444455556601"
        );
        let runtime = &sessions[runtime_id];
        assert_eq!(
            runtime.provider_variant.as_deref(),
            Some("auto-review:0299aaaa-1111-2222-3333-444455556602")
        );
        assert_eq!(runtime.harness.as_deref(), Some("chatgptWork"));
        assert!(sessions[normal_id].provider_variant.is_none());
        assert!(sessions[replay_id].provider_variant.is_none());
        assert_eq!(sessions[replay_id].harness.as_deref(), Some("codex"));
    }

    #[test]
    fn codex_cwd_ignores_blank_metadata_and_trims_later_value() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        std::fs::write(
            sessions.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\",\"cwd\":\"   \"}}\n\
             {\"type\":\"session_meta\",\"payload\":{\"cwd\":\" /Users/example/project/ \"}}\n",
        )
        .unwrap();
        assert_eq!(
            discover_codex(dir.path(), 1)[0].project_dir.as_deref(),
            Some("/Users/example/project/")
        );
    }

    #[test]
    fn codex_tail_id_must_still_match_the_filename_uuid() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let path = sessions.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl");
        let mut file = std::fs::File::create(path).unwrap();
        for _ in 0..12 {
            writeln!(file, "{{\"type\":\"event_msg\"}}").unwrap();
        }
        writeln!(
            file,
            "{{\"type\":\"session_meta\",\"payload\":{{\"thread_id\":\"0199bbbb-1111-2222-3333-444455556666\"}}}}"
        )
        .unwrap();
        drop(file);
        assert!(discover_codex(dir.path(), 10).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_discovery_roots_and_components() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        std::fs::create_dir_all(target.join("sessions")).unwrap();
        symlink(&target, dir.path().join(".codex")).unwrap();
        assert!(discover_codex(dir.path(), 10).is_empty());

        let middle = tempfile::tempdir().unwrap();
        let codex = middle.path().join(".codex");
        std::fs::create_dir_all(&codex).unwrap();
        symlink(&target, codex.join("sessions")).unwrap();
        assert!(discover_codex(middle.path(), 10).is_empty());
    }

    #[test]
    fn parses_past_invalid_newest_candidates_and_skips_conflicting_codex_ids() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&codex).unwrap();
        let bad_codex = codex.join("bad.jsonl");
        std::fs::write(&bad_codex, "{}\n").unwrap();
        let valid_codex = codex.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl");
        std::fs::write(
            &valid_codex,
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\"}}\n",
        )
        .unwrap();
        set_modified(&bad_codex, 200);
        set_modified(&valid_codex, 100);
        assert_eq!(discover_codex(dir.path(), 1).len(), 1);
        std::fs::write(
            codex.join("rollout-x-0199bbbb-1111-2222-3333-444455556666.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199cccc-1111-2222-3333-444455556666\"}}\n",
        ).unwrap();
        assert_eq!(discover_codex(dir.path(), 10).len(), 1);

        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        let invalid_claude = claude.join("invalid.jsonl");
        std::fs::write(&invalid_claude, "not json\n").unwrap();
        let valid_claude = claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl");
        std::fs::write(
            &valid_claude,
            "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"meta\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"<command-name>/clear</command-name>\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"real prompt\"}}\n",
        )
        .unwrap();
        set_modified(&invalid_claude, 200);
        set_modified(&valid_claude, 100);
        let sessions = discover_claude(dir.path(), 1);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].title.as_deref(), Some("real prompt"));
    }

    #[test]
    fn strips_codex_ide_envelope_before_truncating_title() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl"), "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\"}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"# Context from my IDE setup:\\nopen file\\n## My request for Codex:\\nRefactor parser\"}]}}\n").unwrap();
        assert_eq!(
            discover_codex(dir.path(), 1)[0].title.as_deref(),
            Some("Refactor parser")
        );
    }

    #[test]
    fn machine_context_stripping_is_linear_across_many_blocks() {
        let block = "<environment_context>x</environment_context>";
        let count = (jsonl::MAX_LINE_BYTES - 32) / block.len();
        let text = format!("{}real prompt", block.repeat(count));
        assert_eq!(human_title_text(&text).as_deref(), Some("real prompt"));
    }

    #[test]
    fn machine_context_stripping_handles_adjacent_and_unclosed_blocks() {
        let adjacent = "<user_instructions>a</user_instructions><environment_context>b</environment_context>real";
        assert_eq!(human_title_text(adjacent).as_deref(), Some("real"));
        assert_eq!(
            human_title_text("keep<environment_context>unfinished").as_deref(),
            Some("keep")
        );
        assert_eq!(human_title_text("<environment_context>unfinished"), None);
    }

    #[test]
    fn machine_context_stripping_preserves_mixed_human_markup() {
        let text = "before<div>human</div><system-reminder>drop</system-reminder>after";
        assert_eq!(
            human_title_text(text).as_deref(),
            Some("before<div>human</div>after")
        );
        assert_eq!(
            human_title_text("请修改AGENTS.md").as_deref(),
            Some("请修改AGENTS.md")
        );
        assert_eq!(
            human_title_text(
                "# AGENTS.md instructions for /Users/example/project\n<instructions>machine</instructions>"
            ),
            None
        );
    }

    #[test]
    fn codex_title_skips_machine_context_and_keeps_later_human_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("rollout-x-0199aaaa-1111-2222-3333-444455556666.jsonl");
        let mut file = std::fs::File::create(path).unwrap();
        writeln!(
            file,
            "{}",
            serde_json::json!({
                "type": "session_meta",
                "payload": {"id": "0199aaaa-1111-2222-3333-444455556666"}
            })
        )
        .unwrap();
        for text in [
            "<user_instructions>machine</user_instructions>\n<environment_context><cwd>/Users/example/project</cwd></environment_context>",
            "# AGENTS.md instructions for /Users/example/project\n<instructions>machine</instructions>",
            "compare <div> tags without changing them",
        ] {
            writeln!(file, "{}", serde_json::json!({
                "type": "response_item",
                "payload": {"type": "message", "role": "user", "content": [{"text": text}]}
            })).unwrap();
        }
        drop(file);
        assert_eq!(
            discover_codex(dir.path(), 1)[0].title.as_deref(),
            Some("compare <div> tags without changing them")
        );
    }

    #[test]
    fn accepts_case_only_codex_id_difference_and_prefers_latest_claude_custom_title() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&codex).unwrap();
        std::fs::write(codex.join("rollout-x-0199AAAA-1111-2222-3333-444455556666.jsonl"), "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\"}}\n").unwrap();
        assert_eq!(discover_codex(dir.path(), 10).len(), 1);

        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl"), "{\"type\":\"user\",\"message\":{\"content\":\"initial\"}}\n{\"type\":\"custom-title\",\"customTitle\":\"old title\"}\n{\"type\":\"custom-title\",\"customTitle\":\"latest title\"}\n").unwrap();
        assert_eq!(
            discover_claude(dir.path(), 10)[0].title.as_deref(),
            Some("latest title")
        );
    }

    #[test]
    fn uses_valid_tail_metadata_and_normalizes_fallback_titles() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&codex).unwrap();
        let codex_file = codex.join("rollout-tail.jsonl");
        let mut codex_lines = String::new();
        for _ in 0..10 {
            codex_lines.push_str("{\"type\":\"event_msg\"}\n");
        }
        codex_lines.push_str(
            "{\"type\":\"session_meta\",\"payload\":{\"thread_id\":\" \",\"cwd\":\"  \"}}\n",
        );
        codex_lines.push_str(
            "{\"type\":\"session_meta\",\"payload\":{\"thread_id\":\" thread-from-tail \",\"cwd\":\" /Users/example/tail-project/ \"}}\n",
        );
        std::fs::write(&codex_file, codex_lines).unwrap();
        let discovered_codex = discover_codex(dir.path(), 10);
        assert_eq!(discovered_codex[0].session_id, "thread-from-tail");
        assert_eq!(
            discovered_codex[0].project_dir.as_deref(),
            Some("/Users/example/tail-project/")
        );

        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        let claude_file = claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl");
        let mut claude_lines = String::new();
        for _ in 0..13 {
            claude_lines.push_str("not json\n");
        }
        claude_lines.push_str("{\"type\":\"assistant\",\"cwd\":\"/Users/example/my-project/\",\"message\":{\"content\":\"tail only\"}}\n");
        std::fs::write(&claude_file, claude_lines).unwrap();
        let discovered = discover_claude(dir.path(), 10);
        assert_eq!(
            discovered[0].project_dir.as_deref(),
            Some("/Users/example/my-project/")
        );
        assert_eq!(discovered[0].title.as_deref(), Some("my-project"));

        assert_eq!(
            truncate_title("  first\n\tsecond   third  "),
            "first second third"
        );
        assert_eq!(truncate_title(&"x ".repeat(100)).chars().count(), 81);
    }

    #[test]
    fn rejects_jsonl_leaves_without_valid_head_or_tail_and_orders_ties_stably() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&codex).unwrap();
        std::fs::write(codex.join("rollout-bad.jsonl"), "not json\n").unwrap();
        let first = codex.join("rollout-a-0199aaaa-1111-2222-3333-444455556666.jsonl");
        let second = codex.join("rollout-b-0199bbbb-1111-2222-3333-444455556666.jsonl");
        std::fs::write(&first, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\"}}\n").unwrap();
        std::fs::write(&second, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199bbbb-1111-2222-3333-444455556666\"}}\n").unwrap();
        set_modified(&first, 100);
        set_modified(&second, 100);
        let sessions = discover_codex(dir.path(), 10);
        assert_eq!(sessions.len(), 2);
        assert!(sessions[0].source_path < sessions[1].source_path);

        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(
            claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl"),
            "",
        )
        .unwrap();
        std::fs::write(
            claude.join("aaaabbbb-cccc-dddd-eeee-ffff00002222.jsonl"),
            "not json\n",
        )
        .unwrap();
        assert!(discover_claude(dir.path(), 10).is_empty());
    }

    #[test]
    fn subsecond_mtime_orders_before_path_tiebreak_and_limit() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join(".codex/sessions");
        std::fs::create_dir_all(&codex).unwrap();
        let older = codex.join("rollout-a-0199aaaa-1111-2222-3333-444455556666.jsonl");
        let newer = codex.join("rollout-z-0199bbbb-1111-2222-3333-444455556666.jsonl");
        std::fs::write(
            &older,
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199aaaa-1111-2222-3333-444455556666\"}}\n",
        )
        .unwrap();
        std::fs::write(
            &newer,
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"0199bbbb-1111-2222-3333-444455556666\"}}\n",
        )
        .unwrap();
        set_modified_precise(&older, 100, 100_000_000);
        set_modified_precise(&newer, 100, 900_000_000);

        let sessions = discover_codex(dir.path(), 1);
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0].session_id,
            "0199bbbb-1111-2222-3333-444455556666"
        );
        assert_eq!(sessions[0].modified_at, 100);
    }

    #[test]
    fn claude_non_uuid_files_use_recorded_session_id_and_merge_title_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(
            claude.join("legacy-session.jsonl"),
            "{\"type\":\"user\",\"sessionId\":\"recorded-session\",\"message\":{\"content\":[{\"text\":\"first\"},{\"text\":\"second\"}]}}\n",
        )
        .unwrap();
        std::fs::write(
            claude.join("agent-child.jsonl"),
            "{\"type\":\"user\",\"sessionId\":\"child\",\"message\":{\"content\":\"skip\"}}\n",
        )
        .unwrap();

        let sessions = discover_claude(dir.path(), 10);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "recorded-session");
        assert_eq!(sessions[0].title.as_deref(), Some("first second"));
    }

    #[test]
    fn claude_blank_tail_session_id_falls_back_to_nonempty_head_id() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        let path = claude.join("legacy-session.jsonl");
        let mut file = std::io::BufWriter::new(std::fs::File::create(path).unwrap());
        writeln!(
            file,
            "{{\"type\":\"user\",\"sessionId\":\"head-valid\",\"message\":{{\"content\":\"head prompt\"}}}}"
        )
        .unwrap();
        for _ in 0..=jsonl::MAX_TAIL_LINES {
            writeln!(file, "{{\"type\":\"progress\"}}").unwrap();
        }
        writeln!(
            file,
            "{{\"type\":\"user\",\"sessionId\":\"   \",\"message\":{{\"content\":\"tail\"}}}}"
        )
        .unwrap();
        drop(file);

        let sessions = discover_claude(dir.path(), 1);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "head-valid");
    }

    #[test]
    fn claude_cwd_ignores_blank_values_and_trims_head_and_tail() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(
            claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl"),
            "{\"type\":\"user\",\"cwd\":\"   \",\"message\":{\"content\":\"first\"}}\n\
             {\"type\":\"user\",\"cwd\":\" /Users/example/head \",\"message\":{\"content\":\"second\"}}\n",
        )
        .unwrap();
        let tail_path = claude.join("aaaabbbb-cccc-dddd-eeee-ffff00002222.jsonl");
        let mut tail_file = std::io::BufWriter::new(std::fs::File::create(tail_path).unwrap());
        writeln!(
            tail_file,
            "{{\"type\":\"user\",\"cwd\":\" \\t \",\"message\":{{\"content\":\"first\"}}}}"
        )
        .unwrap();
        for _ in 0..12 {
            writeln!(tail_file, "{{\"type\":\"progress\"}}").unwrap();
        }
        writeln!(
            tail_file,
            "{{\"type\":\"assistant\",\"cwd\":\" /Users/example/tail/ \",\"message\":{{\"content\":\"done\"}}}}"
        )
        .unwrap();
        drop(tail_file);

        let sessions = discover_claude(dir.path(), 10);
        let cwd_by_id: std::collections::HashMap<_, _> = sessions
            .into_iter()
            .map(|session| (session.session_id, session.project_dir))
            .collect();
        assert_eq!(
            cwd_by_id["aaaabbbb-cccc-dddd-eeee-ffff00001111"].as_deref(),
            Some("/Users/example/head")
        );
        assert_eq!(
            cwd_by_id["aaaabbbb-cccc-dddd-eeee-ffff00002222"].as_deref(),
            Some("/Users/example/tail/")
        );
    }

    #[test]
    fn claude_meta_head_supplies_cwd_without_supplying_title_content() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        let path = claude.join("aaaabbbb-cccc-dddd-eeee-ffff00003333.jsonl");
        let mut file = std::io::BufWriter::new(std::fs::File::create(path).unwrap());
        writeln!(
            file,
            "{{\"type\":\"user\",\"isMeta\":true,\"cwd\":\" /Users/example/meta-only \",\"message\":{{\"content\":\"machine title\"}}}}"
        )
        .unwrap();
        for _ in 0..=jsonl::MAX_TAIL_LINES {
            writeln!(file, "{{\"type\":\"progress\"}}").unwrap();
        }
        drop(file);

        let session = discover_claude(dir.path(), 1).remove(0);
        assert_eq!(
            session.project_dir.as_deref(),
            Some("/Users/example/meta-only")
        );
        assert_eq!(session.title.as_deref(), Some("meta-only"));
    }

    #[test]
    fn claude_title_skips_machine_notifications_and_keeps_human_markup() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join(".claude/projects/p");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(
            claude.join("aaaabbbb-cccc-dddd-eeee-ffff00001111.jsonl"),
            "{\"type\":\"user\",\"message\":{\"content\":\"<task-notification><result>done</result></task-notification>\"}}\n\
             {\"type\":\"user\",\"message\":{\"content\":\"<cross-session-message>worker update</cross-session-message>\"}}\n\
             {\"type\":\"user\",\"message\":{\"content\":\"keep ordinary <span> markup\"}}\n",
        )
        .unwrap();
        assert_eq!(
            discover_claude(dir.path(), 1)[0].title.as_deref(),
            Some("keep ordinary <span> markup")
        );
    }

    fn set_modified(path: &Path, seconds: u64) {
        set_modified_precise(path, seconds, 0);
    }

    fn set_modified_precise(path: &Path, seconds: u64, nanos: u32) {
        let file = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        let times = std::fs::FileTimes::new()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::new(seconds, nanos));
        file.set_times(times).unwrap();
    }
}
