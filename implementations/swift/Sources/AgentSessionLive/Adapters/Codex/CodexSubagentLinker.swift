import AgentSessionKit
import Foundation
import Synchronization

/// Remembers which Codex thread spawned which, so a child discovered on its
/// own can be attached to the parent that asked for it.
///
/// A Codex sub-agent writes a rollout of its own, in the same tree, with no
/// back-reference in it: the child's header names its own thread and, in some
/// vintages, the root thread — never the tool call that spawned it. The only
/// record of that call is on the *parent* side, as
/// `event_msg.sub_agent_activity` with `kind: "started"`, and by the time
/// discovery sees the child's file the parent's tailer may have read that
/// record minutes ago.
///
/// So the adapter keeps the edge: every ``AgentEventKind/subagentStarted(child:agentType:toolUseID:)``
/// a tailer produces is recorded here, and ``discover(home:activeSince:)``
/// consults it when it seeds a child's identity. Nothing is ever removed —
/// the map holds one small entry per sub-agent seen this run, and forgetting
/// an edge would silently orphan a child that is still running.
///
/// **Not an actor.** ``JSONLTailer`` decodes through a synchronous
/// `@Sendable` closure, which cannot `await`; a lock is the only way to share
/// mutable state with it. The critical sections are a dictionary insert and a
/// lookup.
public final class CodexSubagentLinker: Sendable {
    /// One parent → child edge, with the evidence behind it.
    public struct Link: Hashable, Sendable {
        /// The session whose transcript recorded the spawn.
        public let parent: SessionKey
        /// The parent's id for the spawning call, when the record carried one.
        public let toolUseID: String?

        public init(parent: SessionKey, toolUseID: String?) {
            self.parent = parent
            self.toolUseID = toolUseID
        }
    }

    private let links = Mutex<[String: Link]>([:])

    /// Creates an empty linker.
    public init() {}

    /// Records every spawn edge in `events`.
    ///
    /// Called from a tailer's decode closure with that tailer's own output, so
    /// the parent of each edge is the session the events belong to. A repeated
    /// `started` for a child already known is ignored: the first record is the
    /// one with the call that actually spawned it.
    public func record(_ events: [AgentEvent]) {
        var pending: [String: Link] = [:]
        for event in events {
            guard case let .subagentStarted(child, _, toolUseID) = event.kind else { continue }
            pending[child.sessionID] = Link(parent: event.session, toolUseID: toolUseID)
        }
        guard !pending.isEmpty else { return }
        links.withLock { store in
            for (childID, link) in pending where store[childID] == nil {
                store[childID] = link
            }
        }
    }

    /// The parent recorded for a child thread id, or `nil` when no parent's
    /// transcript has been read yet.
    public func link(forChild sessionID: String) -> Link? {
        links.withLock { $0[sessionID] }
    }

    /// How many edges are held. Diagnostics and tests only.
    public var count: Int {
        links.withLock { $0.count }
    }
}
