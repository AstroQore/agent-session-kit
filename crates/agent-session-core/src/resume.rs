//! Mirror of Swift `SessionResumeCommandBuilder`. Pure string construction —
//! nothing here spawns a process. The host decides whether to copy the line
//! to the clipboard or hand it to a terminal.

use crate::error::SessionCoreError;
use crate::provider::SessionProvider;

pub const ANTIGRAVITY_CLI_VARIANT: &str = "cli";
const MAX_SESSION_ID_LENGTH: usize = 200;

/// Builds the shell command that reopens a session in its own CLI.
pub fn command(
    provider: SessionProvider,
    session_id: &str,
    variant: Option<&str>,
) -> Result<String, SessionCoreError> {
    let id = session_id.trim();
    if !is_valid(id, provider) {
        return Err(SessionCoreError::InvalidSessionId);
    }
    match provider {
        SessionProvider::Claude => Ok(format!("claude --resume {id}")),
        SessionProvider::Codex => Ok(format!("codex resume {id}")),
        SessionProvider::Grok => Ok(format!("grok --resume {id}")),
        SessionProvider::Gemini => Ok(format!("gemini --resume {id}")),
        SessionProvider::Antigravity => {
            // Only the CLI surface takes a conversation id; the IDE sessions
            // have no documented command-line entry point.
            if variant != Some(ANTIGRAVITY_CLI_VARIANT) {
                return Err(SessionCoreError::ResumeUnavailable);
            }
            Ok(format!("agy --conversation {id}"))
        }
        SessionProvider::ClaudeCowork | SessionProvider::Cursor | SessionProvider::GrokBot => {
            // Cowork runs inside Claude.app and Cursor's agents inside Cursor;
            // neither publishes a "reopen this conversation" command. Grok Bot
            // has no CLI at all.
            Err(SessionCoreError::ResumeUnavailable)
        }
    }
}

/// Builds a POSIX-shell-only `cd '<dir>' && <command>` line.
///
/// This is intentionally not a cross-platform launcher. Windows hosts must
/// pass the command and working directory as process arguments, or implement
/// quoting for their selected shell.
pub fn posix_shell_line(cwd: Option<&str>, command: &str) -> String {
    match cwd {
        Some(dir) if !dir.trim().is_empty() => {
            format!("cd {} && {command}", posix_single_quoted(dir))
        }
        _ => command.to_string(),
    }
}

/// POSIX single-quoting: everything between the quotes is literal, and an
/// embedded quote is spelled `'\''` — close, escape, reopen.
pub fn posix_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn is_valid(id: &str, provider: SessionProvider) -> bool {
    if id.is_empty() || id.chars().count() > MAX_SESSION_ID_LENGTH {
        return false;
    }
    match provider {
        SessionProvider::Claude
        | SessionProvider::ClaudeCowork
        | SessionProvider::Codex
        | SessionProvider::Cursor
        | SessionProvider::Antigravity
        | SessionProvider::GrokBot => id.chars().all(|c| c.is_ascii_hexdigit() || c == '-'),
        SessionProvider::Grok | SessionProvider::Gemini => id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_known_commands() {
        assert_eq!(
            command(
                SessionProvider::Codex,
                "0199a2b3-1111-2222-3333-444455556666",
                None
            )
            .unwrap(),
            "codex resume 0199a2b3-1111-2222-3333-444455556666"
        );
        assert_eq!(
            command(SessionProvider::Claude, "ABCDEF01-2345", None).unwrap(),
            "claude --resume ABCDEF01-2345"
        );
        assert_eq!(
            command(
                SessionProvider::Antigravity,
                "abc123",
                Some(ANTIGRAVITY_CLI_VARIANT)
            )
            .unwrap(),
            "agy --conversation abc123"
        );
    }

    #[test]
    fn refuses_unresumable_and_invalid() {
        assert!(matches!(
            command(SessionProvider::Cursor, "abc", None),
            Err(SessionCoreError::ResumeUnavailable)
        ));
        assert!(matches!(
            command(SessionProvider::Antigravity, "abc123", None),
            Err(SessionCoreError::ResumeUnavailable)
        ));
        assert!(matches!(
            command(SessionProvider::Codex, "abc; rm -rf /", None),
            Err(SessionCoreError::InvalidSessionId)
        ));
        assert!(matches!(
            command(SessionProvider::Codex, "", None),
            Err(SessionCoreError::InvalidSessionId)
        ));
    }

    #[test]
    fn posix_shell_line_quotes_cwd() {
        assert_eq!(
            posix_shell_line(Some("/tmp/it's here"), "codex resume x"),
            "cd '/tmp/it'\\''s here' && codex resume x"
        );
        assert_eq!(posix_shell_line(None, "codex resume x"), "codex resume x");
        assert_eq!(
            posix_shell_line(Some("  "), "codex resume x"),
            "codex resume x"
        );
    }
}
