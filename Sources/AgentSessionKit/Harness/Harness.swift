import Foundation

/// Canonical display names for every local harness this package scans.
///
/// A *harness* is the CLI or app that actually produced the sessions on
/// disk — the usage axis, not the billing axis. Two harnesses can draw on
/// one vendor's quota (Claude Code and Claude Cowork both spend
/// Anthropic's), and one company can own several harnesses.
///
/// | Harness        | Company    | Local evidence                                              |
/// | -------------- | ---------- | ----------------------------------------------------------- |
/// | Codex          | OpenAI     | `~/.codex/sessions` rollouts, every other `originator` (`Codex Desktop`, `codex-tui`, `codex_cli_rs`, `codex_exec`, `codex_vscode`) |
/// | ChatGPT Work   | OpenAI     | same tree, `originator` == "codex_work_desktop"              |
/// | Claude Code    | Anthropic  | `~/.claude/projects`, `~/.config/claude/projects`            |
/// | Claude Cowork  | Anthropic  | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects` |
/// | Gemini CLI     | Google AI  | `~/.gemini/tmp/*/chats/session-*.jsonl`                      |
/// | AntiGravity    | Google AI  | `~/.gemini/antigravity{,-cli,-ide}/conversations`            |
/// | Grok Build     | xAI        | `~/.grok/sessions/**/updates.jsonl`                          |
/// | Cursor         | Anysphere  | `~/.cursor/chats/**/store.db`                                |
///
/// Renaming a harness is one edit here, not a hunt across a UI.
public enum HarnessCatalog {
    public static let codex = "Codex"
    public static let chatgptWork = "ChatGPT Work"
    public static let claudeCode = "Claude Code"
    public static let claudeCowork = "Claude Cowork"
    /// Deliberately *not* "Gemini Web": Gemini Web is a billing-side
    /// SubProvider with no local sessions at all, and this deprecated CLI
    /// still owns real historical transcripts under `~/.gemini/tmp`.
    public static let geminiCLI = "Gemini CLI"
    public static let antigravity = "AntiGravity"
    public static let grokBuild = "Grok Build"
    public static let cursor = "Cursor"
}

/// The local harness a session or usage event came from — the unit every
/// usage surface groups by. See `HarnessCatalog` for the full table.
///
/// Declaration order is the display order: harnesses grouped by the company
/// that owns them.
///
/// Host applications that also model a *billing* axis add their own mapping
/// as an extension in their own module; this package deliberately knows
/// nothing about quotas, plans, or prices.
public enum Harness: String, CaseIterable, Codable, Sendable, Hashable {
    case codex
    case chatgptWork
    case claudeCode
    case claudeCowork
    case geminiCLI
    case antigravity
    case grokBuild
    case cursor

    public var displayName: String {
        switch self {
        case .codex:        HarnessCatalog.codex
        case .chatgptWork:  HarnessCatalog.chatgptWork
        case .claudeCode:   HarnessCatalog.claudeCode
        case .claudeCowork: HarnessCatalog.claudeCowork
        case .geminiCLI:    HarnessCatalog.geminiCLI
        case .antigravity:  HarnessCatalog.antigravity
        case .grokBuild:    HarnessCatalog.grokBuild
        case .cursor:       HarnessCatalog.cursor
        }
    }
}
