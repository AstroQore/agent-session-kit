import Foundation
import Synchronization

/// The `agent-<id>.meta.json` that sits beside every subagent transcript.
public struct ClaudeSubagentMeta: Hashable, Sendable {
    /// The named agent type — `general-purpose`, `Explore`, a project's own.
    public let agentType: String?
    /// The one-line description the parent gave the `Task` call. The best
    /// title a child session will ever have.
    public let description: String?
    /// The parent's `tool_use` id for the call that spawned this child. The
    /// only field that links the two files together.
    public let toolUseID: String?
    /// How deep the spawn chain is; `1` for a child of a top-level session.
    public let spawnDepth: Int?
    /// The model the child was launched with, when the parent named one.
    public let model: String?

    /// Creates a meta record.
    public init(
        agentType: String? = nil,
        description: String? = nil,
        toolUseID: String? = nil,
        spawnDepth: Int? = nil,
        model: String? = nil
    ) {
        self.agentType = agentType
        self.description = description
        self.toolUseID = toolUseID
        self.spawnDepth = spawnDepth
        self.model = model
    }

    /// Reads and parses one `agent-<id>.meta.json`, or returns `nil`.
    ///
    /// A missing or malformed sidecar is not an error: the transcript beside
    /// it is still a real session and is still worth tailing, just without a
    /// title or a link back to the call that spawned it.
    public static func read(path: String) -> ClaudeSubagentMeta? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ClaudeSubagentMeta(
            agentType: ClaudeJSON.string(object["agentType"]),
            description: ClaudeJSON.string(object["description"]),
            toolUseID: ClaudeJSON.string(object["toolUseId"]),
            spawnDepth: ClaudeJSON.int(object["spawnDepth"]),
            model: ClaudeJSON.string(object["model"])
        )
    }
}

/// Announces a Claude Code subagent's life on its *parent's* event stream.
///
/// ## Why this exists
///
/// The two halves of a subagent are recorded in two files that share nothing
/// but a tool-use id, and neither half can produce the link on its own:
///
/// - The parent writes `tool_use { id: "toolu_…", name: "Task" }`. It records
///   the *call*, never the child's `agentId` — that id is invented after the
///   line is written.
/// - The child writes `subagents/agent-<agentId>.jsonl` plus an
///   `agent-<agentId>.meta.json` carrying `toolUseId`. It records the *link*,
///   but the child's own tailer has no business emitting events attributed to
///   a session it is not reading.
///
/// So the join happens where both facts are visible: discovery, which sees the
/// meta file and knows which parent's directory it was under. This type holds
/// the resulting links and a small queue of events per parent, and the
/// parent's tailer drains that queue on its next poll — which is why
/// ``AgentEventKind/subagentStarted(child:agentType:toolUseID:)`` shows up on
/// the parent's stream a poll or two after the `Task` tool call did, rather
/// than on the same line.
///
/// ## Lifecycle
///
/// - **Started** on first sight of a child source, once per child.
/// - **Finished** when the child's own tailer reads a ``AgentEventKind/turnEnded(reason:)``
///   or ``AgentEventKind/sessionEnded(reason:)``.
/// - **Started again** if that child then produces more events. A subagent
///   ends every turn the same way it ends its last one, and nothing in the
///   file says which turn was final, so "finished" is a claim that has to be
///   withdrawable. Re-announcing is cheap and idempotent: the reducer keeps
///   `children` as a de-duplicated roster and `openChildren` as a set.
///
/// ## Bounds
///
/// A parent that is never tailed — its transcript fell outside the discovery
/// window while a child of it did not — would otherwise accumulate events
/// forever. Each parent's queue is capped at ``queueLimit`` and drops from the
/// front, because the newest verdict about a child is the one worth keeping.
public final class ClaudeSubagentLinker: Sendable {
    /// Most queued events held for one parent before the oldest are dropped.
    public static let queueLimit = 128

    private struct Link: Sendable {
        let parent: SessionKey
        let agentType: String?
        let toolUseID: String?
    }

    private struct State {
        var links: [SessionKey: Link] = [:]
        var open: Set<SessionKey> = []
        var queues: [SessionKey: [AgentEventKind]] = [:]
    }

    private let state = Mutex(State())

    /// Creates an empty linker.
    public init() {}

    /// Records a parent/child link, queueing a `subagentStarted` on the
    /// parent the first time a child is seen.
    ///
    /// Idempotent: discovery runs every fifteen seconds and hands over the
    /// same children each time.
    public func register(
        child: SessionKey,
        parent: SessionKey,
        agentType: String?,
        toolUseID: String?
    ) {
        state.withLock { state in
            guard state.links[child] == nil else { return }
            state.links[child] = Link(parent: parent, agentType: agentType, toolUseID: toolUseID)
            state.open.insert(child)
            enqueue(
                .subagentStarted(child: child, agentType: agentType, toolUseID: toolUseID),
                for: parent,
                in: &state
            )
        }
    }

    /// Folds what a child's tailer just read into the parent's queue.
    ///
    /// Called with the child's own events, which are forwarded unchanged; the
    /// only thing taken from them is whether the child closed a turn.
    public func childProduced(_ events: [AgentEvent], child: SessionKey) {
        guard !events.isEmpty else { return }
        let finished = events.contains { event in
            switch event.kind {
            case .turnEnded, .sessionEnded: true
            default: false
            }
        }
        state.withLock { state in
            guard let link = state.links[child] else { return }
            if finished {
                guard state.open.remove(child) != nil else { return }
                enqueue(.subagentFinished(child: child), for: link.parent, in: &state)
            } else if state.open.insert(child).inserted {
                // The child spoke again after we called it finished. See the
                // type's discussion.
                enqueue(
                    .subagentStarted(
                        child: child, agentType: link.agentType, toolUseID: link.toolUseID
                    ),
                    for: link.parent,
                    in: &state
                )
            }
        }
    }

    /// Takes everything queued for `parent`, as events stamped `now`.
    ///
    /// These carry the observation clock in both ``AgentEvent/timestamp`` and
    /// ``AgentEvent/observedAt`` because there is no source record behind
    /// them: the fact being reported is "a child transcript appeared", and the
    /// moment it was noticed is the only time anyone knows.
    public func drain(parent: SessionKey, now: Date) -> [AgentEvent] {
        let kinds = state.withLock { state in
            state.queues.removeValue(forKey: parent) ?? []
        }
        return kinds.map { AgentEvent(session: parent, timestamp: now, observedAt: now, kind: $0) }
    }

    /// The parent of `child`, when one was registered. Diagnostics and tests.
    public func parent(of child: SessionKey) -> SessionKey? {
        state.withLock { $0.links[child]?.parent }
    }

    private func enqueue(_ kind: AgentEventKind, for parent: SessionKey, in state: inout State) {
        var queue = state.queues[parent] ?? []
        queue.append(kind)
        if queue.count > Self.queueLimit {
            queue.removeFirst(queue.count - Self.queueLimit)
        }
        state.queues[parent] = queue
    }
}
