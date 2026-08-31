import Foundation

/// Maps a Codex rollout's `session_meta.originator` onto a harness.
///
/// One `~/.codex/sessions` tree holds transcripts from every Codex surface,
/// and only the header says which. `codex_work_desktop` is ChatGPT **Work**
/// mode in the desktop app. Everything else we have seen — `Codex Desktop`
/// (the desktop app's Codex tab), `codex-tui`, `codex_cli_rs`, `codex_exec`,
/// `codex_vscode` — is ordinary Codex, so anything unrecognised, including a
/// missing header, stays on the Codex harness rather than being invented as
/// ChatGPT Work usage.
public enum CodexOriginator {
    public static let chatgptWork = "codex_work_desktop"

    public static func harness(originator: String?) -> Harness {
        originator == chatgptWork ? .chatgptWork : .codex
    }
}
