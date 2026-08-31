import Foundation

/// One tailable thing: the files or database that carry a single session.
///
/// Not every session is one file. Grok Build splits a session across
/// `events.jsonl` and `updates.jsonl`; Claude Code writes a subagent's turns
/// into a sibling directory of the parent's transcript. `primaryPath` is the
/// one whose ordering defines the session's timeline, and `auxiliaryPaths`
/// are the rest — a watcher subscribes to all of them, a cursor spans all of
/// them (see ``SourceCursor/composite(_:)``).
///
/// `seedIdentity` is what discovery could learn cheaply, from the head and
/// tail of the source. It is a starting point, not a conclusion: the tailer
/// refines it with ``AgentEventKind/identityUpdated(_:)`` as it reads.
public struct SessionSource: Hashable, Codable, Sendable {
    /// Which session this source carries.
    public let key: SessionKey
    /// The file or database whose order defines the session's timeline.
    public let primaryPath: String
    /// Further paths belonging to the same session, in no particular order.
    public let auxiliaryPaths: [String]
    /// What discovery could learn without reading the whole source.
    public let seedIdentity: SessionIdentity

    /// Creates a source description.
    public init(
        key: SessionKey,
        primaryPath: String,
        auxiliaryPaths: [String] = [],
        seedIdentity: SessionIdentity
    ) {
        self.key = key
        self.primaryPath = primaryPath
        self.auxiliaryPaths = auxiliaryPaths
        self.seedIdentity = seedIdentity
    }

    /// `primaryPath` followed by `auxiliaryPaths` — everything a watcher has
    /// to subscribe to.
    public var allPaths: [String] { [primaryPath] + auxiliaryPaths }
}
