import AgentSessionKit
import Foundation
import Synchronization

/// What the CLI's summaries store said about each conversation the last time
/// discovery read it.
///
/// Three facts live only in `conversation_summaries.db` and nowhere in a
/// conversation's own database: which conversation spawned it, whether it is
/// busy right now, and whether it was killed. All three are wanted in places
/// that must not do SQL — a tailer's `poll()`, which runs per source per
/// change, and `probeLiveness`, which is synchronous by protocol. So discovery
/// reads the store once and leaves the answers here.
///
/// This is also where the parent → child edge becomes an event. A row that
/// spawned a sub-agent records only `has_subtrajectory`, never *which*
/// conversation the child is, so a tailer cannot name a child from its own
/// database. The summaries store can, from the child's side, and a parent's
/// tailer emits ``AgentEventKind/subagentStarted(child:agentType:toolUseID:)``
/// once the registry knows about a child of its conversation — the same shape
/// `CodexSubagentLinker` uses, with the direction of discovery reversed.
///
/// **Not an actor.** ``AntigravityLiveAdapter/probeLiveness(_:table:home:)`` is
/// synchronous by protocol and cannot `await`. The critical sections are a
/// dictionary lookup and a merge.
public final class AntigravityConversationRegistry: Sendable {
    /// One conversation, as the index describes it.
    public struct Entry: Hashable, Sendable {
        /// The conversation that spawned this one.
        public let parentConversationID: String?
        /// How deep in a sub-agent tree it sits.
        public let nestingDepth: Int
        /// `not_fully_idle`: it is doing something right now.
        public let notFullyIdle: Bool
        /// `killed`: it was terminated rather than finished.
        public let killed: Bool
        /// A label for the thread, when the index had one.
        public let title: String?
        /// The first workspace, as a plain path.
        public let workspacePath: String?

        /// Creates an entry.
        public init(
            parentConversationID: String?,
            nestingDepth: Int,
            notFullyIdle: Bool,
            killed: Bool,
            title: String?,
            workspacePath: String?
        ) {
            self.parentConversationID = parentConversationID
            self.nestingDepth = nestingDepth
            self.notFullyIdle = notFullyIdle
            self.killed = killed
            self.title = title
            self.workspacePath = workspacePath
        }

        /// Builds an entry from a summaries row.
        public init(_ summary: AntigravitySummariesReader.Summary) {
            self.init(
                parentConversationID: summary.parentConversationID?.lowercased(),
                nestingDepth: summary.nestingDepth,
                notFullyIdle: summary.notFullyIdle,
                killed: summary.killed,
                title: summary.title,
                workspacePath: summary.workspacePath
            )
        }
    }

    private struct Store {
        var entries: [String: Entry] = [:]
        var children: [String: Set<String>] = [:]
    }

    private let store = Mutex(Store())

    /// Creates an empty registry.
    public init() {}

    /// Merges a batch of summaries, replacing what was known about each id.
    ///
    /// Nothing is ever removed. A conversation that dropped out of the index's
    /// recent window is still a conversation a board may be showing, and
    /// forgetting its parent would orphan it mid-run.
    public func record(_ summaries: [AntigravitySummariesReader.Summary]) {
        guard !summaries.isEmpty else { return }
        store.withLock { store in
            for summary in summaries {
                let id = summary.conversationID.lowercased()
                let entry = Entry(summary)
                store.entries[id] = entry
                if let parent = entry.parentConversationID, parent != id {
                    store.children[parent, default: []].insert(id)
                }
            }
        }
    }

    /// What is known about one conversation.
    public func entry(for conversationID: String) -> Entry? {
        store.withLock { $0.entries[conversationID.lowercased()] }
    }

    /// The conversation that spawned `conversationID`, when the index named
    /// one.
    public func parent(of conversationID: String) -> String? {
        entry(for: conversationID)?.parentConversationID
    }

    /// Every conversation the index says `parentID` spawned, sorted so a
    /// tailer's output is stable across runs.
    public func children(of parentID: String) -> [String] {
        store.withLock { $0.children[parentID.lowercased()] ?? [] }.sorted()
    }

    /// How many conversations are known. Diagnostics and tests only.
    public var count: Int {
        store.withLock { $0.entries.count }
    }
}
