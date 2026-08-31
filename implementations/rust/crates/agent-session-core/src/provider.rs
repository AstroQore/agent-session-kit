use serde::{Deserialize, Serialize};

/// Mirror of the Swift `SessionProvider` enum. Raw values are storage keys in
/// `session_index.sqlite3` — they must match the Swift implementation
/// byte-for-byte and never change without a coordinated schema note.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SessionProvider {
    #[serde(rename = "claude")]
    Claude,
    #[serde(rename = "claudeCowork")]
    ClaudeCowork,
    #[serde(rename = "codex")]
    Codex,
    #[serde(rename = "grok")]
    Grok,
    #[serde(rename = "cursor")]
    Cursor,
    #[serde(rename = "gemini")]
    Gemini,
    #[serde(rename = "antigravity")]
    Antigravity,
    #[serde(rename = "grokBot")]
    GrokBot,
}

impl SessionProvider {
    pub const ALL: [SessionProvider; 8] = [
        SessionProvider::Claude,
        SessionProvider::ClaudeCowork,
        SessionProvider::Codex,
        SessionProvider::Grok,
        SessionProvider::Cursor,
        SessionProvider::Gemini,
        SessionProvider::Antigravity,
        SessionProvider::GrokBot,
    ];

    /// Storage raw value — identical to Swift's `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            SessionProvider::Claude => "claude",
            SessionProvider::ClaudeCowork => "claudeCowork",
            SessionProvider::Codex => "codex",
            SessionProvider::Grok => "grok",
            SessionProvider::Cursor => "cursor",
            SessionProvider::Gemini => "gemini",
            SessionProvider::Antigravity => "antigravity",
            SessionProvider::GrokBot => "grokBot",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|p| p.raw_value() == raw)
    }

    /// Harness display name — mirrors `HarnessCatalog` on the Swift side.
    /// (Codex sessions with the ChatGPT Work originator carry the harness
    /// column value "ChatGPT Work" in the index; this mapping is the default
    /// per provider.)
    pub fn default_harness(self) -> &'static str {
        match self {
            SessionProvider::Claude => "Claude Code",
            SessionProvider::ClaudeCowork => "Claude Cowork",
            SessionProvider::Codex => "Codex",
            SessionProvider::Grok => "Grok Build",
            SessionProvider::Cursor => "Cursor",
            SessionProvider::Gemini => "Gemini CLI",
            SessionProvider::Antigravity => "AntiGravity",
            SessionProvider::GrokBot => "Grok Bot",
        }
    }

    /// Mirrors Swift `SessionProvider.supportsDeletion` — kept here so a
    /// future deletion feature fails closed for the read-only stores even if
    /// the UI forgets to check.
    pub fn supports_deletion(self) -> bool {
        matches!(
            self,
            SessionProvider::Claude
                | SessionProvider::Codex
                | SessionProvider::Grok
                | SessionProvider::Gemini
        )
    }
}
