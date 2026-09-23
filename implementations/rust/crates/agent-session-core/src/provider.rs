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
    #[serde(rename = "muse")]
    Muse,
    #[serde(rename = "devin")]
    Devin,
    #[serde(rename = "mistralVibe")]
    MistralVibe,
    #[serde(rename = "museAgent")]
    MuseAgent,
}

impl SessionProvider {
    pub const ALL: [SessionProvider; 12] = [
        SessionProvider::Claude,
        SessionProvider::ClaudeCowork,
        SessionProvider::Codex,
        SessionProvider::Grok,
        SessionProvider::Cursor,
        SessionProvider::Gemini,
        SessionProvider::Antigravity,
        SessionProvider::GrokBot,
        SessionProvider::Muse,
        SessionProvider::Devin,
        SessionProvider::MistralVibe,
        SessionProvider::MuseAgent,
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
            SessionProvider::Muse => "muse",
            SessionProvider::Devin => "devin",
            SessionProvider::MistralVibe => "mistralVibe",
            SessionProvider::MuseAgent => "museAgent",
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
            SessionProvider::Muse => "Muse Code",
            SessionProvider::Devin => "Devin",
            SessionProvider::MistralVibe => "Mistral Vibe",
            SessionProvider::MuseAgent => "Muse",
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_values_round_trip_and_match_serde() {
        for provider in SessionProvider::ALL {
            assert_eq!(
                SessionProvider::from_raw(provider.raw_value()),
                Some(provider)
            );
            assert_eq!(
                serde_json::to_string(&provider).unwrap(),
                format!("\"{}\"", provider.raw_value())
            );
        }
        assert_eq!(SessionProvider::Devin.raw_value(), "devin");
        assert_eq!(SessionProvider::MistralVibe.raw_value(), "mistralVibe");
        assert_eq!(SessionProvider::Devin.default_harness(), "Devin");
        assert_eq!(
            SessionProvider::MistralVibe.default_harness(),
            "Mistral Vibe"
        );
        assert_eq!(SessionProvider::MuseAgent.raw_value(), "museAgent");
        assert_eq!(SessionProvider::MuseAgent.default_harness(), "Muse");
        assert_eq!(
            serde_json::from_str::<SessionProvider>("\"museAgent\"").unwrap(),
            SessionProvider::MuseAgent
        );
        // Muse (the desktop agent app) and Muse Code (the `muse` CLI) are
        // different stores and must never collapse onto one key.
        assert_ne!(
            SessionProvider::Muse.raw_value(),
            SessionProvider::MuseAgent.raw_value()
        );
        assert_ne!(
            SessionProvider::Muse.default_harness(),
            SessionProvider::MuseAgent.default_harness()
        );
    }

    #[test]
    fn read_only_providers_refuse_deletion() {
        for provider in [
            SessionProvider::ClaudeCowork,
            SessionProvider::Cursor,
            SessionProvider::Antigravity,
            SessionProvider::GrokBot,
            SessionProvider::Muse,
            SessionProvider::Devin,
            SessionProvider::MistralVibe,
            SessionProvider::MuseAgent,
        ] {
            assert!(!provider.supports_deletion(), "{provider:?}");
        }
    }
}
