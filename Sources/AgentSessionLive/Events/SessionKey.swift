import AgentSessionKit
import Foundation

/// The identity of one live session: which harness produced it, and that
/// harness's own id for it.
///
/// Session ids are only unique *within* a harness — Codex and Claude Code
/// both write UUIDs, and nothing stops the same UUID appearing in both
/// trees. Pairing the id with its `Harness` is what makes a key global.
///
/// `description` is the canonical string form, `"<harness rawValue>:<id>"`,
/// and it is what a host stores as a database key or a dictionary key in
/// JSON. `Harness.rawValue` is frozen for exactly this reason, and so is
/// the separator: changing either orphans stored rows.
///
/// The id half may itself contain colons (AntiGravity's conversation ids
/// and Cursor's blob ids both can), so parsing splits on the *first* colon
/// only.
public struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The CLI or app that produced the session on disk.
    public let harness: Harness
    /// The harness's own identifier for the session, verbatim.
    public let sessionID: String

    /// Creates a key from a harness and that harness's session id.
    public init(harness: Harness, sessionID: String) {
        self.harness = harness
        self.sessionID = sessionID
    }

    /// Parses the canonical `"<harness>:<id>"` form produced by
    /// ``description``.
    ///
    /// Returns `nil` when there is no colon, when the harness half is not a
    /// known ``Harness`` raw value, or when the id half is empty. Everything
    /// after the first colon is the id, colons included.
    public init?(string: String) {
        guard let separator = string.firstIndex(of: ":") else { return nil }
        let harnessPart = String(string[string.startIndex..<separator])
        let idPart = String(string[string.index(after: separator)...])
        guard let harness = Harness(rawValue: harnessPart), !idPart.isEmpty else { return nil }
        self.harness = harness
        self.sessionID = idPart
    }

    /// The canonical string form, `"<harness rawValue>:<session id>"`.
    public var description: String { "\(harness.rawValue):\(sessionID)" }
}

/// How a child session came to be attached to a parent — the evidence, not
/// a guess.
///
/// Auspex links sessions across harnesses (a Claude Code turn that shells
/// out to `codex exec` is a real parent/child pair), and the link is only
/// as trustworthy as the thing that produced it. Keeping the provenance on
/// the edge lets a host show a firm line for a recorded tool call and a
/// dotted one for a process-tree inference.
public enum ParentLink: Hashable, Codable, Sendable {
    /// The parent's transcript recorded a tool call that spawned the child —
    /// Claude's `Task`, Codex's `spawn_agent`, an AntiGravity subtrajectory.
    /// `toolUseID` is the parent's id for that call when the log carries one.
    case subagent(toolUseID: String?)
    /// The child's process is a descendant of the parent's pid. This is the
    /// only evidence available when a harness shells out to another harness.
    case spawnedProcess
    /// The child process inherited the parent's session environment variable.
    case envInherited
    /// A person linked the two in the UI. Never inferred, never overwritten.
    case manual
}

extension ParentLink {
    /// How much this kind of evidence is worth, higher being stronger.
    ///
    /// The one place the ranking is written down, so that everything which has
    /// to choose between two answers — ``SessionIdentityPatch/applied(to:)``,
    /// ``ProcessLinker``, a host's own merge — chooses the same way:
    /// `manual` > `subagent` > `envInherited` > `spawnedProcess`.
    ///
    /// The order is the order of how directly each one was *observed*. A person
    /// saying so is not evidence that can be wrong. A logged spawn is the
    /// parent's own record of the act. An inherited session id is an
    /// identifier only the parent could have written. A process ancestry is a
    /// relationship a shared shell produces just as readily as a spawn.
    public var precedence: Int {
        switch self {
        case .manual: 3
        case .subagent: 2
        case .envInherited: 1
        case .spawnedProcess: 0
        }
    }
}
