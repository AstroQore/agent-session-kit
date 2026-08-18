import AgentSessionKit
import Foundation
import Synchronization

/// Tails one AntiGravity conversation database by *diffing* it.
///
/// ## Why this is not a cursor walk
///
/// Every other tailer in this package advances past records it has read,
/// because every other store appends. AntiGravity rewrites: `steps` is keyed
/// by `idx`, and one row's `status` column walks `PENDING → RUNNING → DONE`
/// in place as the call it describes proceeds. A tailer that only read rows
/// past its cursor would emit `toolCallStarted` and never the matching
/// `toolCallFinished`, leaving every session on a board permanently busy.
///
/// So a poll reads two things: rows past the cursor, and the rows still open
/// behind it. Whether a row *changed* is decided by comparing against
/// ``AntigravityStepMapper/RowState`` held in memory, and only the transitions
/// produce events.
///
/// ## The cursor, and what a restart costs
///
/// ``cursor`` is `.rowID(lastIndex)` — the highest `idx` consumed. That is all
/// a persisted cursor can carry, and it is deliberately not enough to
/// reconstruct which rows were open when the process stopped. On resume the
/// tailer re-reads the last ``resumeLookback`` rows and *adopts* them without
/// emitting: a row still open is assumed to have had its opening event
/// emitted by the previous run, so its close will still pair; a row already
/// terminal is taken as done with.
///
/// The gap that leaves is one case, and it is worth naming: a step that opened
/// **and** closed while Auspex was not running produces neither event. Its
/// `toolCallStarted` was emitted before the restart and its
/// `toolCallFinished` is adopted away, so a host that persisted the snapshot
/// too will see one tool call that never closed. The alternative — re-emitting
/// closes for the whole lookback window on every restart — trades a rare
/// missing pair for a routine burst of duplicates, which is the worse deal.
public final class AntigravityConversationTailer: SessionTailer {
    /// How far behind the cursor a resume re-reads before trusting it.
    ///
    /// Thirty-two rows is a couple of turns' worth: enough that a tool call
    /// open at shutdown is found again, small enough to be one indexed query.
    public static let resumeLookback = 32

    /// Rows one poll will read. A conversation that grew more than this
    /// between two polls is read across several of them.
    public static let maxRowsPerPoll = AntigravityConversationReader.maxRowsPerPoll

    /// Steps a cold start reads from the end of the conversation, when the
    /// caller's byte budget does not say otherwise.
    public static let defaultSeedSteps = 64

    /// Reasons a tailer gives up. Never thrown for a row it could not make
    /// sense of — only for a database it could not read at all.
    public enum Failure: Error, Hashable, Sendable {
        /// The file is there and SQLite would not give up its rows, even from
        /// a private snapshot copy.
        case unreadable(path: String)
    }

    public let source: SessionSource

    /// The conversation database being read.
    public let databaseURL: URL

    /// Where parent → child edges and the `killed` flag come from. Shared with
    /// the adapter that built this tailer.
    private let registry: AntigravityConversationRegistry
    private let reader: AntigravityConversationReader
    private let state: Mutex<State>

    private struct State {
        /// Highest `idx` consumed. `-1` before anything has been read.
        var lastIndex: Int
        /// Per-row comparison state, pruned to the rows a later poll can still
        /// re-read.
        var rows: [Int: AntigravityStepMapper.RowState]
        /// The next poll must re-read behind the cursor and adopt what it
        /// finds, because this tailer was built from a persisted cursor.
        var needsResumeScan: Bool
        /// Monotonic per-tailer event order.
        var sequence: Int64
        /// A turn is open and has not been closed by a `turnEnded` yet.
        var turnOpen: Bool
        /// Children already announced, so a re-read of the registry does not
        /// announce them twice.
        var announcedChildren: Set<String>
        /// `sessionEnded(.killed)` has gone out.
        var announcedKilled: Bool
    }

    /// Creates a tailer over a conversation database.
    ///
    /// - Parameters:
    ///   - source: The session this database belongs to.
    ///   - cursor: Where to resume. A cursor of another shape — a byte offset,
    ///     a blob head — is discarded rather than rejected: a store that
    ///     changed representation should re-seed, not fail.
    ///   - registry: Where discovery left the summaries store's answers.
    public init(
        source: SessionSource,
        cursor: SourceCursor?,
        registry: AntigravityConversationRegistry = AntigravityConversationRegistry()
    ) {
        self.source = source
        self.databaseURL = URL(fileURLWithPath: source.primaryPath)
        self.registry = registry
        self.reader = AntigravityConversationReader(databaseURL: databaseURL)
        let resumeIndex = Self.rowID(in: cursor, path: source.primaryPath)
        self.state = Mutex(State(
            lastIndex: resumeIndex ?? -1,
            rows: [:],
            needsResumeScan: resumeIndex != nil,
            sequence: 0,
            turnOpen: false,
            announcedChildren: [],
            announcedKilled: false
        ))
    }

    /// The highest `idx` consumed so far.
    public var cursor: SourceCursor {
        .rowID(Int64(state.withLock { $0.lastIndex }))
    }

    /// Rows still open behind the cursor. Diagnostics and tests only.
    public var openRowCount: Int {
        state.withLock { $0.rows.values.filter { $0.status.isOpen }.count }
    }

    // MARK: - Reading

    /// Everything that changed since the last poll.
    ///
    /// Cheap when nothing moved: one indexed `WHERE idx >= ?` that returns the
    /// handful of rows at the end of the conversation, and a dictionary
    /// comparison that produces no events.
    public func poll() async throws -> [AgentEvent] {
        try read(floorOverride: nil, limit: Self.maxRowsPerPoll)
    }

    /// Cold start: the last few steps of the conversation, and nothing before
    /// them.
    ///
    /// `maxBytes` is the caller's budget in the currency of a JSONL
    /// transcript. A step row is a kilobyte or so of payload, so it is spent
    /// here as one step per kilobyte, bounded either way.
    public func seedFromTail(maxBytes: Int = 64 * 1024) async throws -> [AgentEvent] {
        let steps = max(8, min(256, maxBytes / 1024))
        guard let last = reader.lastStepIndex() else {
            // No rows yet, or no database yet. Both are ordinary for a
            // conversation that was created a moment ago.
            return []
        }
        state.withLock { $0.needsResumeScan = false }
        return try read(floorOverride: max(0, last - steps + 1), limit: steps)
    }

    private func read(floorOverride: Int?, limit: Int) throws -> [AgentEvent] {
        guard FileManager.default.fileExists(atPath: source.primaryPath) else { return [] }

        let plan = state.withLock { state -> (floor: Int, resuming: Bool) in
            if let floorOverride { return (floorOverride, false) }
            var floor = state.lastIndex + 1
            if let oldestOpen = state.rows.filter({ $0.value.status.isOpen }).keys.min() {
                floor = min(floor, oldestOpen)
            }
            if state.needsResumeScan {
                floor = min(floor, max(0, state.lastIndex - Self.resumeLookback + 1))
            }
            return (max(0, floor), state.needsResumeScan)
        }

        guard let rows = reader.steps(fromIndex: plan.floor, limit: limit) else {
            throw Failure.unreadable(path: source.primaryPath)
        }
        let reachedEnd = rows.count < limit

        return state.withLock { state in
            var events: [AgentEvent] = []
            let now = Date()

            for row in rows {
                // A row consumed before a restart is adopted, not replayed.
                if plan.resuming, row.idx <= state.lastIndex, state.rows[row.idx] == nil {
                    state.rows[row.idx] = AntigravityStepMapper.resumedState(for: row)
                    state.lastIndex = max(state.lastIndex, row.idx)
                    if row.status.isOpen { state.turnOpen = true }
                    continue
                }
                let previous = state.rows[row.idx]
                if let previous, previous.status == row.status {
                    state.lastIndex = max(state.lastIndex, row.idx)
                    continue
                }
                let mapped = AntigravityStepMapper.map(
                    row: row,
                    previous: previous,
                    session: source.key,
                    sourcePath: source.primaryPath,
                    now: now
                )
                events.append(contentsOf: mapped.events)
                state.rows[row.idx] = mapped.state
                state.lastIndex = max(state.lastIndex, row.idx)
                if row.status.isOpen { state.turnOpen = true }
                if mapped.events.contains(where: { if case .turnStarted = $0.kind { true } else { false } }) {
                    state.turnOpen = true
                }
            }
            state.needsResumeScan = false

            // A turn closes when the conversation has settled: every row read
            // to the end of the table is terminal and none is still open.
            let anyOpen = state.rows.values.contains { $0.status.isOpen }
            if state.turnOpen, reachedEnd, !anyOpen,
               let reason = AntigravityStepMapper.turnEnd(rows: rows) {
                events.append(AgentEvent(
                    session: source.key,
                    timestamp: rows.last?.payload?.endedAt ?? now,
                    observedAt: now,
                    kind: .turnEnded(reason: reason)
                ))
                state.turnOpen = false
            }

            events.append(contentsOf: sideChannel(state: &state, now: now))
            prune(&state)
            return stamped(events, state: &state)
        }
    }

    /// Events the conversation's own rows cannot produce: the children the
    /// summaries store attributes to this conversation, and the `killed` flag.
    private func sideChannel(state: inout State, now: Date) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let conversationID = source.key.sessionID
        for childID in registry.children(of: conversationID)
        where state.announcedChildren.insert(childID).inserted {
            events.append(AgentEvent(
                session: source.key,
                timestamp: now,
                observedAt: now,
                kind: .subagentStarted(
                    child: SessionKey(harness: .antigravity, sessionID: childID),
                    agentType: nil,
                    toolUseID: nil
                )
            ))
        }
        if !state.announcedKilled, registry.entry(for: conversationID)?.killed == true {
            state.announcedKilled = true
            events.append(AgentEvent(
                session: source.key,
                timestamp: now,
                observedAt: now,
                kind: .sessionEnded(reason: .killed)
            ))
        }
        return events
    }

    /// Drops comparison state for rows no later poll can read again.
    ///
    /// The floor a poll computes is `min(oldest open row, cursor + 1)`, so
    /// every terminal row below it is out of reach forever and holding it
    /// would grow the map with the conversation.
    private func prune(_ state: inout State) {
        var floor = state.lastIndex + 1
        if let oldestOpen = state.rows.filter({ $0.value.status.isOpen }).keys.min() {
            floor = min(floor, oldestOpen)
        }
        let keep = max(0, floor - Self.resumeLookback)
        guard state.rows.count > Self.resumeLookback * 4 else { return }
        state.rows = state.rows.filter { $0.key >= keep || $0.value.status.isOpen }
    }

    /// Assigns this tailer's monotonic order. The mapper leaves it alone
    /// because only the tailer knows what it emitted before.
    private func stamped(_ events: [AgentEvent], state: inout State) -> [AgentEvent] {
        events.map { event in
            state.sequence += 1
            return AgentEvent(
                id: event.id,
                session: event.session,
                timestamp: event.timestamp,
                observedAt: event.observedAt,
                sequence: state.sequence,
                kind: event.kind,
                raw: event.raw
            )
        }
    }

    /// The row id inside a cursor, whatever shape it arrived in.
    static func rowID(in cursor: SourceCursor?, path: String) -> Int? {
        switch cursor {
        case let .rowID(value): Int(value)
        case let .composite(members): rowID(in: members[path], path: path)
        case .byteOffset, .blobHead, .none: nil
        }
    }
}
