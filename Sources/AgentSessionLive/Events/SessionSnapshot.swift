import Foundation

/// A tool call that started and has not finished.
///
/// Held so that finishing an *inner* call can restore the state of the one
/// still open around it, and so that a turn that ends with calls still open
/// can be recognised as having orphaned them.
public struct PendingToolCall: Hashable, Codable, Sendable {
    /// The harness's own call id — the key that ``AgentEventKind/toolCallFinished(id:isError:)``
    /// matches on.
    public let id: String
    /// The raw tool name, as the harness spells it.
    public let name: String
    /// The normalised activity.
    public let kind: ToolKind
    /// The file path, command, url, or MCP server the call is aimed at.
    public let target: String?
    /// The timestamp of the `toolCallStarted` event.
    public let startedAt: Date

    /// Creates a record of an open tool call.
    public init(id: String, name: String, kind: ToolKind, target: String?, startedAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
        self.startedAt = startedAt
    }
}

/// A permission prompt that is on screen and unanswered.
///
/// Modelled as a struct rather than a tuple so that it is `Codable` and
/// `Hashable` along with the rest of the snapshot.
public struct PendingPermission: Hashable, Codable, Sendable {
    /// The harness's own id for the prompt, matched by
    /// ``AgentEventKind/permissionResolved(id:allowed:)``.
    public let id: String
    /// The tool the prompt is about, when the source named one.
    public let tool: String?

    /// Creates a record of an open permission prompt.
    public init(id: String, tool: String?) {
        self.id = id
        self.tool = tool
    }
}

/// Everything a session has open right now.
///
/// The reducer keeps this so that finishing one thing can *derive* the next
/// state instead of guessing it: when a tool call ends, what the session is
/// doing depends entirely on whether a permission, a child, or another tool
/// call is still outstanding.
public struct PendingSet: Hashable, Codable, Sendable {
    /// Open tool calls, keyed by the harness's call id.
    public var openToolCalls: [String: PendingToolCall]
    /// Child sessions that have started and not finished.
    public var openChildren: Set<SessionKey>
    /// The unanswered permission prompt, when there is one. At most one is
    /// tracked: a harness blocks on a prompt, so a second cannot be open
    /// while the first is.
    public var openPermission: PendingPermission?
    /// The timestamp of the most recent event, whatever its kind.
    public var lastEventAt: Date?
    /// When the current turn opened, or `nil` when no turn is open.
    public var currentTurnStartedAt: Date?

    /// Creates a pending set. Everything defaults to empty.
    public init(
        openToolCalls: [String: PendingToolCall] = [:],
        openChildren: Set<SessionKey> = [],
        openPermission: PendingPermission? = nil,
        lastEventAt: Date? = nil,
        currentTurnStartedAt: Date? = nil
    ) {
        self.openToolCalls = openToolCalls
        self.openChildren = openChildren
        self.openPermission = openPermission
        self.lastEventAt = lastEventAt
        self.currentTurnStartedAt = currentTurnStartedAt
    }

    /// `true` when nothing at all is outstanding.
    public var isEmpty: Bool {
        openToolCalls.isEmpty && openChildren.isEmpty && openPermission == nil
    }

    /// The open tool call that started last.
    ///
    /// Ties on `startedAt` are broken by call id, so the answer is
    /// deterministic even when a harness flushes a whole turn with one
    /// timestamp. Without a tie-break the result would depend on dictionary
    /// iteration order, which is not stable between runs.
    public var mostRecentOpenToolCall: PendingToolCall? {
        openToolCalls.values.max { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.id < rhs.id
        }
    }
}

/// The complete derived view of one session — what a board renders per row.
///
/// Produced only by ``SessionStateReducer``: seed one with
/// ``SessionStateReducer/initialSnapshot(identity:)`` and fold every event
/// into it. It is a value, so a host can keep the previous one to diff
/// against, hand a copy to a view, or persist it, with no locking.
public struct SessionSnapshot: Hashable, Codable, Sendable {
    /// Everything known about the session that is not a state or a counter.
    public var identity: SessionIdentity
    /// What the session is doing.
    public var state: SessionState
    /// Whether the harness process is believed to be running. Set by
    /// ``AgentEventKind/liveness(alive:)`` and by session start/end events;
    /// never inferred from silence.
    public var isAlive: Bool
    /// `true` when the session claims to be working but has not said
    /// anything for longer than the reducer's `staleAfter`. A stale session
    /// is not an ended one — a long `swift build` looks exactly like this —
    /// so this is a flag on the row, not a state.
    public var isStale: Bool
    /// What is currently open.
    public var pending: PendingSet
    /// Timestamp of the most recent event. Mirrors ``PendingSet/lastEventAt``
    /// and is duplicated here because it is what a UI sorts on.
    public var lastEventAt: Date?
    /// When the session was first seen or started.
    public var startedAt: Date?
    /// When it ended, or `nil` while it has not. Cleared on resurrection.
    public var endedAt: Date?
    /// How many turns have opened.
    public var turnCount: Int
    /// How many tool calls have started, open or not.
    public var toolCallCount: Int
    /// Sum of `usage` input tokens.
    public var tokensIn: Int
    /// Sum of `usage` output tokens.
    public var tokensOut: Int
    /// Sum of `usage` cached tokens.
    public var tokensCached: Int
    /// Every child ever spawned, in the order they were spawned. Cumulative:
    /// finished children stay, so a UI can show the whole tree of a turn.
    /// The children still *running* are ``PendingSet/openChildren``.
    public var children: [SessionKey]

    /// Creates a snapshot. Prefer ``SessionStateReducer/initialSnapshot(identity:)``;
    /// this initializer exists for tests and for rehydrating from a store.
    public init(
        identity: SessionIdentity,
        state: SessionState = .idle,
        isAlive: Bool = true,
        isStale: Bool = false,
        pending: PendingSet = PendingSet(),
        lastEventAt: Date? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        turnCount: Int = 0,
        toolCallCount: Int = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        tokensCached: Int = 0,
        children: [SessionKey] = []
    ) {
        self.identity = identity
        self.state = state
        self.isAlive = isAlive
        self.isStale = isStale
        self.pending = pending
        self.lastEventAt = lastEventAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.tokensCached = tokensCached
        self.children = children
    }

    /// The session's key, for convenience.
    public var key: SessionKey { identity.key }
}
