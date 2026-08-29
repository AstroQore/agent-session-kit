//! Tolerant transcript parsing for Codex and Claude Code JSONL session logs.
//!
//! Renders what is legible and skips what is not — a transcript reader must
//! never fail an entire session because one line is malformed or belongs to a
//! newer schema.

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::jsonl;
use crate::provider::SessionProvider;

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
pub struct TranscriptPage {
    pub messages: Vec<TranscriptMessage>,
    pub total_messages: usize,
    pub offset: usize,
}

/// Parse a transcript page from a session log. Only Codex and Claude Code are
/// supported in this slice; other providers return an empty page.
pub fn read_page(
    provider: SessionProvider,
    path: &Path,
    offset: usize,
    limit: usize,
) -> std::io::Result<TranscriptPage> {
    let mut all: Vec<TranscriptMessage> = Vec::new();
    match provider {
        SessionProvider::Codex => {
            jsonl::for_each_json_line(path, |line| {
                if let Some(message) = codex_message(&line) {
                    all.push(message);
                }
                true
            })?;
        }
        SessionProvider::Claude => {
            jsonl::for_each_json_line(path, |line| {
                if let Some(message) = claude_message(&line) {
                    all.push(message);
                }
                true
            })?;
        }
        _ => {}
    }
    let total = all.len();
    let page: Vec<TranscriptMessage> = all.into_iter().skip(offset).take(limit.max(1)).collect();
    Ok(TranscriptPage {
        messages: page,
        total_messages: total,
        offset,
    })
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
                    Some(TranscriptMessage { role, text, timestamp })
                }
                "function_call" => {
                    let name = payload.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                    Some(TranscriptMessage {
                        role: TranscriptRole::Tool,
                        text: format!("[tool call] {name}"),
                        timestamp,
                    })
                }
                "function_call_output" => Some(TranscriptMessage {
                    role: TranscriptRole::Tool,
                    text: "[tool result]".to_string(),
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
            if let Some(text) = content.as_str() {
                if !text.trim().is_empty() {
                    parts.push(text.trim().to_string());
                }
            } else if let Some(blocks) = content.as_array() {
                for block in blocks {
                    match block.get("type").and_then(|v| v.as_str()) {
                        Some("text") => {
                            if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
                                if !text.trim().is_empty() {
                                    parts.push(text.trim().to_string());
                                }
                            }
                        }
                        Some("tool_use") => {
                            let name =
                                block.get("name").and_then(|v| v.as_str()).unwrap_or("tool");
                            parts.push(format!("[tool call] {name}"));
                        }
                        Some("tool_result") => parts.push("[tool result]".to_string()),
                        Some("thinking") => {}
                        _ => {}
                    }
                }
            }
            if parts.is_empty() {
                return None;
            }
            // A user line whose only content is tool results renders as Tool.
            let all_tool = parts.iter().all(|p| p.starts_with("[tool "));
            let role = if all_tool { TranscriptRole::Tool } else { role };
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
        writeln!(f, "{}", serde_json::json!({
            "type": "session_meta", "payload": {"id": "x"}
        })).unwrap();
        writeln!(f, "{}", serde_json::json!({
            "type": "response_item", "timestamp": "2026-08-30T04:00:00Z",
            "payload": {"type": "message", "role": "user",
                        "content": [{"type": "input_text", "text": "hello"}]}
        })).unwrap();
        writeln!(f, "{}", serde_json::json!({
            "type": "response_item",
            "payload": {"type": "function_call", "name": "Bash", "arguments": "{}"}
        })).unwrap();
        writeln!(f, "{}", serde_json::json!({
            "type": "response_item",
            "payload": {"type": "message", "role": "assistant",
                        "content": [{"type": "output_text", "text": "done"}]}
        })).unwrap();
        drop(f);

        let page = read_page(SessionProvider::Codex, &path, 0, 50).unwrap();
        assert_eq!(page.total_messages, 3);
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
        writeln!(f, "{}", serde_json::json!({
            "type": "user", "timestamp": "t0",
            "message": {"role": "user", "content": "do the thing"}
        })).unwrap();
        writeln!(f, "{}", serde_json::json!({
            "type": "assistant", "timestamp": "t1",
            "message": {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "hmm"},
                {"type": "text", "text": "on it"},
                {"type": "tool_use", "name": "Bash", "input": {}}
            ]}
        })).unwrap();
        writeln!(f, "{}", serde_json::json!({"type": "queue-operation"})).unwrap();
        drop(f);

        let page = read_page(SessionProvider::Claude, &path, 1, 10).unwrap();
        assert_eq!(page.total_messages, 2);
        assert_eq!(page.messages.len(), 1);
        assert!(page.messages[0].text.contains("on it"));
        assert!(page.messages[0].text.contains("[tool call] Bash"));
    }
}
