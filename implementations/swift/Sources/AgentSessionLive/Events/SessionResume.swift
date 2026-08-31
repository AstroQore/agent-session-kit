import AgentSessionKit
import Foundation

/// Whether a live session can be reopened in its own CLI, and the line to do
/// it with.
///
/// Modelled as an answer rather than a `String?` because "no" is a thing a UI
/// has to render: a menu item that quietly disappears teaches nobody why, and
/// three of the nine harnesses genuinely have no command-line entry point. The
/// reason is written for a person to read in a disabled menu item or a
/// tooltip.
public enum SessionResumeAvailability: Hashable, Sendable {
    /// The session can be reopened. `command` is the bare CLI invocation and
    /// `shellLine` prefixes it with a `cd` into the session's own working
    /// directory when one was recorded.
    case available(command: String, shellLine: String)
    /// The session cannot be reopened, and why — a sentence, not an error code.
    case unavailable(reason: String)

    /// The bare CLI invocation, or `nil`.
    public var command: String? {
        guard case let .available(command, _) = self else { return nil }
        return command
    }

    /// The cwd-aware shell line, or `nil`.
    public var shellLine: String? {
        guard case let .available(_, shellLine) = self else { return nil }
        return shellLine
    }

    /// Why not, or `nil` when it can be resumed.
    public var reason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }

    /// `true` when there is a command to run.
    public var isAvailable: Bool { command != nil }
}

/// Asks, of a live session, "how do I get back to this one?".
///
/// `AgentSessionKit`'s `SessionResumeCommandBuilder` already knows the answer
/// per *provider*; a live board holds ``SessionIdentity`` values keyed by
/// *harness*, and it also holds the two facts the builder needs and an indexed
/// row does not — the AntiGravity variant that decides whether a conversation
/// id means anything, and the working directory to land in. This is the join.
///
/// Nothing here spawns a process. The host decides whether to copy the line to
/// a clipboard or hand it to a terminal, and a person clicks first.
public enum SessionResume: Sendable {
    /// The shell line that reopens `identity`'s session, or `nil` when its
    /// harness has no way to.
    ///
    /// Cwd-aware: `cd '<cwd>' && <command>` when the identity recorded a
    /// working directory, the bare command when it did not. Single-quoted the
    /// POSIX way, because a path comes off disk and this string is meant to be
    /// pasted into a shell.
    public static func resumeCommand(for identity: SessionIdentity) -> String? {
        availability(for: identity).shellLine
    }

    /// The full answer, including the sentence to show when there is none.
    public static func availability(for identity: SessionIdentity) -> SessionResumeAvailability {
        let harness = identity.key.harness
        do {
            let command = try SessionResumeCommandBuilder.command(
                provider: harness.sessionProvider,
                sessionID: identity.key.sessionID,
                variant: identity.variant
            )
            return .available(
                command: command,
                shellLine: SessionResumeCommandBuilder.shellLine(cwd: identity.cwd, command: command)
            )
        } catch {
            return .unavailable(reason: reason(for: error, identity: identity))
        }
    }

    /// Whether a harness has any command-line resume at all, before an
    /// identity is in hand.
    ///
    /// AntiGravity answers `true` here and may still answer `unavailable` for
    /// a given session: only its CLI surface takes a conversation id.
    public static func isResumable(_ harness: Harness) -> Bool {
        switch harness {
        case .claudeCowork, .cursor, .grokBot: false
        case .codex, .chatgptWork, .claudeCode, .geminiCLI, .antigravity, .grokBuild: true
        }
    }

    // MARK: - Reasons

    private static func reason(for error: any Error, identity: SessionIdentity) -> String {
        guard let resumeError = error as? SessionResumeError else {
            return "This session cannot be resumed from the command line."
        }
        switch resumeError {
        case .invalidSessionID:
            return invalidIDReason(identity)
        case .resumeUnavailable:
            return unavailableReason(identity)
        }
    }

    /// A session id the builder refuses. In practice this is a subagent: the
    /// live layer keys a child transcript as `<parent>/agent-<id>`, which is a
    /// locator inside a parent session rather than something a CLI can be
    /// handed.
    private static func invalidIDReason(_ identity: SessionIdentity) -> String {
        if identity.variant == ClaudeLiveAdapter.subagentVariant
            || identity.key.sessionID.contains("/") {
            return "A subagent runs inside its parent session; resume the parent instead."
        }
        return "This session's identifier cannot be used in a shell command."
    }

    private static func unavailableReason(_ identity: SessionIdentity) -> String {
        switch identity.key.harness {
        case .claudeCowork:
            return "Claude Cowork sessions live inside Claude.app and have no command-line resume."
        case .cursor:
            return "Cursor's agents live inside Cursor and have no command-line resume."
        case .grokBot:
            return "Grok Bot conversations run on xAI's servers; there is nothing local to resume."
        case .antigravity:
            return "Only AntiGravity's CLI sessions take a conversation id; an IDE session has none."
        case .codex, .chatgptWork, .claudeCode, .geminiCLI, .grokBuild:
            return "This session cannot be resumed from the command line."
        }
    }
}

public extension Harness {
    /// The on-disk store this harness's sessions live in.
    ///
    /// The inverse of `SessionProvider.defaultHarness`, which is not injective:
    /// Codex and ChatGPT Work share one rollout tree and are told apart only by
    /// the header's `originator`. Everything a *provider* answers — resume
    /// commands, deletability, the discovery roots — is reachable from a
    /// harness through here.
    var sessionProvider: SessionProvider {
        switch self {
        case .codex, .chatgptWork: .codex
        case .claudeCode: .claude
        case .claudeCowork: .claudeCowork
        case .geminiCLI: .gemini
        case .antigravity: .antigravity
        case .grokBuild: .grok
        case .cursor: .cursor
        case .grokBot: .grokBot
        }
    }
}
