import AgentSessionKit
import Foundation

/// The environment variables a harness passes to the processes it launches,
/// naming the session or the process it launched them from.
///
/// This is the whole of the evidence behind ``ParentLink/envInherited``, and
/// it lives in one table rather than in each adapter because the interesting
/// case is *cross*-harness: a Claude Code tool call that runs `codex exec`
/// leaves `CLAUDE_CODE_SESSION_ID` in the Codex process's environment, and
/// neither harness's log records the other. A linker that only knew its own
/// harness's variable could never see that edge.
///
/// ## What is verified and what is not
///
/// `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, and `CLAUDE_CODE_ENTRYPOINT` are
/// observed in the environment of processes Claude Code spawns for tool calls.
/// `CURSOR_AGENT_CHAT_ID` is what ``CursorLiveAdapter`` already matches a
/// worker against, and `ANTIGRAVITY_CONVERSATION_ID` is what
/// ``AntigravityLiveAdapter`` matches an `agy` process against. The rest —
/// `CODEX_SESSION_ID`, `CODEX_THREAD_ID`, `GROK_SESSION_ID`,
/// `ANTIGRAVITY_TRAJECTORY_ID` — are names the shipped binaries reference;
/// whether a given release exports them to its children varies, and a name
/// that is never set simply never matches. Listing one costs a dictionary
/// lookup in a table that was already read.
///
/// Nothing here invents a link: a variable only produces a parent when its
/// value is a session id that is actually on the board.
public enum SessionEnvironmentVariables {
    // MARK: - Names

    /// Claude Code's session id, exported to every process a tool call spawns.
    public static let claudeSessionID = "CLAUDE_CODE_SESSION_ID"
    /// The pid of the Claude Code process behind ``claudeSessionID``.
    public static let claudePID = "CLAUDE_PID"
    /// Codex's session id.
    public static let codexSessionID = "CODEX_SESSION_ID"
    /// Codex's thread id, which is the same identifier under the name newer
    /// builds use for it.
    public static let codexThreadID = "CODEX_THREAD_ID"
    /// Grok Build's session id.
    public static let grokSessionID = "GROK_SESSION_ID"
    /// The agent id `cursor-agent` passes to its own children.
    public static let cursorChatID = "CURSOR_AGENT_CHAT_ID"
    /// AntiGravity's conversation id, set on an `agy` process.
    public static let antigravityConversationID = "ANTIGRAVITY_CONVERSATION_ID"
    /// AntiGravity's trajectory id — a conversation's current run.
    public static let antigravityTrajectoryID = "ANTIGRAVITY_TRAJECTORY_ID"

    // MARK: - Tables

    /// Variables whose value is a ``SessionKey/sessionID`` of that harness,
    /// most specific name first.
    ///
    /// Claude Cowork and ChatGPT Work share the CLI their sibling harness
    /// ships, and therefore its variables.
    public static let sessionIDsByHarness: [Harness: [String]] = [
        .claudeCode: [claudeSessionID],
        .claudeCowork: [claudeSessionID],
        .codex: [codexSessionID, codexThreadID],
        .chatgptWork: [codexSessionID, codexThreadID],
        .grokBuild: [grokSessionID],
        .cursor: [cursorChatID],
        .antigravity: [antigravityConversationID, antigravityTrajectoryID],
    ]

    /// Variables whose value is the *pid* of the harness process rather than
    /// its session id. Weaker evidence than a session id — a pid is only
    /// meaningful while it has not been recycled — but it survives a child
    /// being re-parented, which a process-tree walk does not.
    public static let processIDsByHarness: [Harness: [String]] = [
        .claudeCode: [claudePID],
        .claudeCowork: [claudePID],
    ]

    /// Every session-id variable, deduplicated, in a stable order.
    ///
    /// The order is `Harness.allCases` — declaration order, which is frozen —
    /// so an inference over the same environment produces the same answer on
    /// every run.
    public static let allSessionIDVariables: [String] = deduplicated(sessionIDsByHarness)

    /// Every process-id variable, deduplicated, in a stable order.
    public static let allProcessIDVariables: [String] = deduplicated(processIDsByHarness)

    /// The harnesses whose sessions `variable` can name, in ``Harness``
    /// declaration order. Empty for a name this table does not know.
    public static func harnesses(namedBy variable: String) -> [Harness] {
        Harness.allCases.filter { sessionIDsByHarness[$0]?.contains(variable) == true }
    }

    /// The session-id variables to consult for a process belonging to
    /// `harness`, its own first.
    ///
    /// Own-first is not cosmetic. A `codex exec` started by another Codex
    /// thread, which was itself started by a Claude Code tool call, carries
    /// *both* `CODEX_SESSION_ID` and the inherited `CLAUDE_CODE_SESSION_ID`;
    /// the nearer parent is the Codex one, and it is the one whose variable
    /// the harness sets for its own children.
    public static func sessionIDVariables(for harness: Harness) -> [String] {
        let own = sessionIDsByHarness[harness] ?? []
        return own + allSessionIDVariables.filter { !own.contains($0) }
    }

    private static func deduplicated(_ table: [Harness: [String]]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for harness in Harness.allCases {
            for name in table[harness] ?? [] where seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }
}
