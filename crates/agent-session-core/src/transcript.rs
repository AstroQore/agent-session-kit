//! Tolerant transcript parsing for Codex and Claude Code JSONL session logs.
//!
//! Renders what is legible and skips what is not — a transcript reader must
//! never fail an entire session because one line is malformed or belongs to a
//! newer schema.

use std::fs::File;
use std::io::BufRead;
use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::jsonl;
use crate::provider::SessionProvider;

/// No transcript page can materialize more than this many messages.
pub const MAX_PAGE_MESSAGES: usize = 500;
/// A rendered transcript message is clipped to this many UTF-8 bytes.
pub const MAX_MESSAGE_TEXT_BYTES: usize = 64 * 1024;
/// A request scans at most this much of one JSONL transcript.
pub const MAX_TRANSCRIPT_SCAN_BYTES: u64 = 64 * 1024 * 1024;
/// A request recognizes at most this many transcript messages before it
/// returns a truncated result.
pub const MAX_TRANSCRIPT_SCAN_MESSAGES: usize = 50_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TranscriptRole {
    User,
    Assistant,
    System,
    Tool,
    Note,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranscriptMessage {
    pub role: TranscriptRole,
    pub text: String,
    /// ISO-8601 string as recorded in the log, when present.
    pub timestamp: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptPage {
    pub messages: Vec<TranscriptMessage>,
    /// Exact only when `truncated` is false. A large or actively growing log
    /// deliberately reports `None` rather than a misleading partial total.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_messages: Option<usize>,
    pub offset: usize,
    /// True when the reader reached a scan byte/message safety cap.
    pub truncated: bool,
}

/// Parse a transcript page from a session log. Only Codex and Claude Code are
/// supported in this slice; other providers return an empty page.
pub fn read_page(
    provider: SessionProvider,
    path: &Path,
    offset: usize,
    limit: usize,
) -> std::io::Result<TranscriptPage> {
    // This convenience path API is best-effort: jsonl rejects a symlink/non-
    // regular leaf, but a same-user replacement can still race check/open.
    // Security-sensitive hosts should use read_page_from_file/reader instead.
    let file = jsonl::open_regular_file(path)?;
    read_page_from_file(provider, file, offset, limit)
}

/// Parses a transcript from an already-open file capability.
///
/// Unlike [`read_page`], this function never resolves or reopens a path while
/// parsing. A host that needs a stronger boundary can open the file using its
/// platform-safe policy, then pass the resulting handle here.
pub fn read_page_from_file(
    provider: SessionProvider,
    file: File,
    offset: usize,
    limit: usize,
) -> std::io::Result<TranscriptPage> {
    read_page_from_reader(
        provider,
        std::io::BufReader::with_capacity(256 * 1024, file),
        offset,
        limit,
    )
}

/// Parses a transcript from an already-open buffered reader capability.
pub fn read_page_from_reader<R: BufRead>(
    provider: SessionProvider,
    reader: R,
    offset: usize,
    limit: usize,
) -> std::io::Result<TranscriptPage> {
    match provider {
        SessionProvider::Codex => read_page_with_reader(reader, offset, limit, codex_message),
        SessionProvider::Claude => read_page_with_reader(reader, offset, limit, claude_message),
        _ => Ok(TranscriptPage {
            messages: Vec::new(),
            total_messages: Some(0),
            offset,
            truncated: false,
        }),
    }
}

fn read_page_with_reader<R: BufRead>(
    reader: R,
    offset: usize,
    limit: usize,
    parse: fn(&Value) -> Option<TranscriptMessage>,
) -> std::io::Result<TranscriptPage> {
    read_page_with_reader_bounded(
        reader,
        offset,
        limit,
        MAX_TRANSCRIPT_SCAN_BYTES,
        MAX_TRANSCRIPT_SCAN_MESSAGES,
        parse,
    )
}

fn read_page_with_reader_bounded<R: BufRead>(
    reader: R,
    offset: usize,
    limit: usize,
    max_scan_bytes: u64,
    max_scan_messages: usize,
    parse: fn(&Value) -> Option<TranscriptMessage>,
) -> std::io::Result<TranscriptPage> {
    let page_limit = limit.clamp(1, MAX_PAGE_MESSAGES);
    let mut messages: Vec<TranscriptMessage> = Vec::with_capacity(page_limit);
    let mut total_messages = 0usize;
    let mut hit_message_cap = false;
    let mut accept = |message: Option<TranscriptMessage>| {
        let Some(message) = message else { return true };
        if total_messages >= max_scan_messages {
            hit_message_cap = true;
            return false;
        }
        if total_messages >= offset && messages.len() < page_limit {
            messages.push(clip_message(message));
        }
        total_messages += 1;
        true
    };
    let stats = jsonl::for_each_json_line_bounded_reader(reader, max_scan_bytes, |line| {
        accept(parse(&line))
    })?;
    let truncated = stats.truncated || hit_message_cap;
    Ok(TranscriptPage {
        messages,
        total_messages: (!truncated).then_some(total_messages),
        offset,
        truncated,
    })
}

fn clip_message(mut message: TranscriptMessage) -> TranscriptMessage {
    if message.text.len() > MAX_MESSAGE_TEXT_BYTES {
        let mut end = MAX_MESSAGE_TEXT_BYTES.saturating_sub('…'.len_utf8());
        while !message.text.is_char_boundary(end) {
            end -= 1;
        }
        message.text.truncate(end);
        message.text.push('…');
    }
    message
}

fn codex_message(line: &Value) -> Option<TranscriptMessage> {
    let timestamp = line
        .get("timestamp")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    match line.get("type").and_then(|v| v.as_str())? {
        "response_item" => {
            let payload = line.get("payload")?;
            match payload.get("type").and_then(|v| v.as_str())? {
                "message" => {
                    let role = match payload.get("role").and_then(|v| v.as_str())? {
                        "user" => TranscriptRole::User,
                        "assistant" => TranscriptRole::Assistant,
                        "system" | "developer" => TranscriptRole::System,
                        _ => TranscriptRole::Note,
                    };
                    let text = joined_block_text(payload.get("content")?)?;
                    Some(TranscriptMessage {
                        role,
                        text,
                        timestamp,
                    })
                }
                "function_call" => {
                    let name = payload
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("tool");
                    Some(TranscriptMessage {
                        role: TranscriptRole::Tool,
                        text: format!("[tool call] {name}"),
                        timestamp,
                    })
                }
                "function_call_output" => Some(TranscriptMessage {
                    role: TranscriptRole::Tool,
                    text: recorded_text(payload.get("output"))
                        .or_else(|| recorded_text(payload.get("content")))
                        .unwrap_or_else(|| "[tool result]".to_string()),
                    timestamp,
                }),
                "reasoning" => None,
                _ => None,
            }
        }
        _ => None,
    }
}

fn claude_message(line: &Value) -> Option<TranscriptMessage> {
    if line.get("isMeta").and_then(|value| value.as_bool()) == Some(true) {
        return None;
    }
    let timestamp = line
        .get("timestamp")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let line_type = line.get("type").and_then(|v| v.as_str())?;
    match line_type {
        "user" | "assistant" => {
            let message = line.get("message")?;
            let role = match message.get("role").and_then(|v| v.as_str()) {
                Some("user") => TranscriptRole::User,
                Some("assistant") => TranscriptRole::Assistant,
                _ => TranscriptRole::Note,
            };
            let content = message.get("content")?;
            let mut parts: Vec<String> = Vec::new();
            let mut only_tool_results = true;
            if let Some(text) = content.as_str() {
                if !text.trim().is_empty() {
                    parts.push(text.trim().to_string());
                    only_tool_results = false;
                }
            } else if let Some(blocks) = content.as_array() {
                for block in blocks {
                    match block.get("type").and_then(|v| v.as_str()) {
                        Some("text") => {
                            if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
                                if !text.trim().is_empty() {
                                    parts.push(text.trim().to_string());
                                    only_tool_results = false;
                                }
                            }
                        }
                        Some("tool_use") => {
                            let name = block.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                            parts.push(format!("[tool call] {name}"));
                            only_tool_results = false;
                        }
                        Some("tool_result") => parts.push(
                            recorded_text(block.get("content"))
                                .unwrap_or_else(|| "[tool result]".to_string()),
                        ),
                        Some("thinking") => {}
                        _ => {}
                    }
                }
            }
            if parts.is_empty() {
                return None;
            }
            // A user line whose only content is tool results renders as Tool.
            let role = if only_tool_results {
                TranscriptRole::Tool
            } else {
                role
            };
            Some(TranscriptMessage {
                role,
                text: parts.join("\n\n"),
                timestamp,
            })
        }
        "summary" => {
            let text = line.get("summary").and_then(|v| v.as_str())?;
            Some(TranscriptMessage {
                role: TranscriptRole::Note,
                text: format!("[summary] {text}"),
                timestamp,
            })
        }
        _ => None,
    }
}

fn recorded_text(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(text) = value.as_str() {
        let text = text.trim();
        return (!text.is_empty()).then(|| text.to_string());
    }
    if let Some(array) = value.as_array() {
        let parts: Vec<String> = array
            .iter()
            .filter_map(|entry| recorded_text(entry.get("text").or(Some(entry))))
            .collect();
        return (!parts.is_empty()).then(|| parts.join("\n\n"));
    }
    value
        .get("text")
        .or_else(|| value.get("content"))
        .or_else(|| value.get("output"))
        .and_then(|nested| recorded_text(Some(nested)))
}

fn joined_block_text(content: &Value) -> Option<String> {
    let blocks = content.as_array()?;
    let parts: Vec<String> = blocks
        .iter()
        .filter_map(|b| b.get("text").and_then(|v| v.as_str()))
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect();
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parses_codex_transcript() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "session_meta", "payload": {"id": "x"}
            })
        )
        .unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "response_item", "timestamp": "2026-08-30T04:00:00Z",
                "payload": {"type": "message", "role": "user",
                            "content": [{"type": "input_text", "text": "hello"}]}
            })
        )
        .unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "response_item",
                "payload": {"type": "function_call", "name": "Bash", "arguments": "{}"}
            })
        )
        .unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "response_item",
                "payload": {"type": "message", "role": "assistant",
                            "content": [{"type": "output_text", "text": "done"}]}
            })
        )
        .unwrap();
        drop(f);

        let page = read_page(SessionProvider::Codex, &path, 0, 50).unwrap();
        assert_eq!(page.total_messages, Some(3));
        assert!(!page.truncated);
        let wire = serde_json::to_value(&page).unwrap();
        assert_eq!(wire["totalMessages"], 3);
        assert!(wire.get("total_messages").is_none());
        assert_eq!(wire["truncated"], false);
        assert_eq!(page.messages[0].role, TranscriptRole::User);
        assert_eq!(page.messages[0].text, "hello");
        assert_eq!(page.messages[1].role, TranscriptRole::Tool);
        assert_eq!(page.messages[2].role, TranscriptRole::Assistant);
    }

    #[test]
    fn parses_claude_transcript_and_pages() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "user", "timestamp": "t0",
                "message": {"role": "user", "content": "do the thing"}
            })
        )
        .unwrap();
        writeln!(
            f,
            "{}",
            serde_json::json!({
                "type": "assistant", "timestamp": "t1",
                "message": {"role": "assistant", "content": [
                    {"type": "thinking", "thinking": "hmm"},
                    {"type": "text", "text": "on it"},
                    {"type": "tool_use", "name": "Bash", "input": {}}
                ]}
            })
        )
        .unwrap();
        writeln!(f, "{}", serde_json::json!({"type": "queue-operation"})).unwrap();
        drop(f);

        let page = read_page(SessionProvider::Claude, &path, 1, 10).unwrap();
        assert_eq!(page.total_messages, Some(2));
        assert_eq!(page.messages.len(), 1);
        assert!(page.messages[0].text.contains("on it"));
        assert!(page.messages[0].text.contains("[tool call] Bash"));
    }

    #[test]
    fn skips_claude_meta_and_keeps_recorded_tool_outputs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        std::fs::write(
            &path,
            concat!(
                "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"role\":\"user\",\"content\":\"ignore\"}}\n",
                "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"actual Claude output\"}]}}\n"
            ),
        )
        .unwrap();
        let page = read_page(SessionProvider::Claude, &path, 0, 10).unwrap();
        assert_eq!(page.total_messages, Some(1));
        assert_eq!(page.messages[0].role, TranscriptRole::Tool);
        assert_eq!(page.messages[0].text, "actual Claude output");
    }

    #[test]
    fn keeps_codex_recorded_function_output() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"actual Codex output\"}}\n",
        )
        .unwrap();
        let page = read_page(SessionProvider::Codex, &path, 0, 10).unwrap();
        assert_eq!(page.messages[0].text, "actual Codex output");
    }

    #[test]
    fn bounds_page_output_and_reports_truncated_scan() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        for index in 0..=MAX_TRANSCRIPT_SCAN_MESSAGES {
            writeln!(f, "{}", serde_json::json!({
                "type": "response_item",
                "payload": {"type": "message", "role": "user",
                            "content": [{"type": "input_text", "text": format!("message {index}")}]}
            })).unwrap();
        }
        drop(f);

        let page = read_page(SessionProvider::Codex, &path, 0, usize::MAX).unwrap();
        assert_eq!(page.messages.len(), MAX_PAGE_MESSAGES);
        assert_eq!(page.total_messages, None);
        assert!(page.truncated);
        let wire = serde_json::to_value(&page).unwrap();
        assert!(wire.get("totalMessages").is_none());
        assert_eq!(wire["truncated"], true);
    }

    #[test]
    fn clips_message_text() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        let text = "x".repeat(MAX_MESSAGE_TEXT_BYTES + 1024);
        std::fs::write(
            &path,
            format!(
                "{}\n",
                serde_json::json!({
                    "type": "response_item",
                    "payload": {"type": "message", "role": "user",
                                "content": [{"type": "input_text", "text": text}]}
                })
            ),
        )
        .unwrap();

        let page = read_page(SessionProvider::Codex, &path, 0, 1).unwrap();
        assert!(page.messages[0].text.len() <= MAX_MESSAGE_TEXT_BYTES);
        assert!(page.messages[0].text.ends_with('…'));
    }

    #[test]
    fn parses_from_an_already_open_file_without_a_path_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"from handle\"}]}}\n",
        )
        .unwrap();

        let file = std::fs::File::open(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        let page = read_page_from_file(SessionProvider::Codex, file, 0, 10).unwrap();
        assert_eq!(page.messages[0].text, "from handle");
        assert_eq!(page.total_messages, Some(1));
    }

    #[test]
    fn transcript_scan_stops_at_its_byte_budget_inside_an_unterminated_line() {
        use std::io::Cursor;

        let input = vec![b'x'; 2 * 1024 * 1024];
        let page = read_page_with_reader_bounded(
            Cursor::new(input),
            0,
            1,
            1024,
            MAX_TRANSCRIPT_SCAN_MESSAGES,
            codex_message,
        )
        .unwrap();
        assert!(page.messages.is_empty());
        assert_eq!(page.total_messages, None);
        assert!(page.truncated);
    }
}
