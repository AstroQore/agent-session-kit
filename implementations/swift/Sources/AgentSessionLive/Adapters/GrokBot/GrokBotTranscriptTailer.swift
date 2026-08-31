import AgentSessionKit
import Foundation
import Synchronization

/// Tails one Grok Bot conversation by *diffing the file against itself*.
///
/// ## Why this is not a cursor walk
///
/// A transcript replica is a JSON document the client rewrites whole. Entries
/// are appended at the end, and an entry already in the array is edited in
/// place while its reply streams — `isStreaming` goes `true → false` and the
/// text it carries grows as the words arrive. There is no byte offset to
/// resume from and no record to read past, so a poll re-reads the document and
/// asks two questions: which entries are new, and which of the ones already
/// read have stopped streaming.
///
/// That is why a streaming entry produces ``AgentEventKind/thinking`` and
/// nothing else. Emitting its text would put half a sentence on a board and
/// then never correct it; the words come out of the read that finds the flag
/// cleared.
///
/// ## Two files, one session
///
/// The replica is the conversation. The roster slice next to it carries the
/// two facts the replica does not: the bot's name, and
/// `awaitingUserResponse` — the client's own "this one is blocked on you"
/// flag, and the only thing anywhere in this store that says a person is
/// needed. The flag becomes ``AgentEventKind/permissionRequested(id:tool:)``
/// with no tool, because that is the event a board renders as *needs you*,
/// and it resolves when the flag clears.
///
/// ## The cursor, and what a restart costs
///
/// ``cursor`` is `.blobHead(<id of the last entry consumed>)`. Entry ids are
/// stable across rewrites, so on resume the id is found again in one pass and
/// only what follows it is new. Two gaps come with that, both deliberate:
///
/// - An entry that was **streaming when Auspex stopped** and finished while it
///   was down is adopted silently; its text is never emitted. Re-emitting the
///   tail on every restart would trade one missing message for a routine burst
///   of duplicates.
/// - If the anchor id is **not in the file any more** — the client replaced
///   the replica, or trimmed its history — everything present is adopted
///   without being emitted, rather than replaying a whole conversation as if
///   it had just happened.
public final class GrokBotTranscriptTailer: SessionTailer {
    /// Entries a cold start reads from the end of the conversation when the
    /// caller's byte budget does not say otherwise.
    public static let defaultSeedEntries = 64

    /// Reasons a tailer gives up. Never thrown for an entry it could not make
    /// sense of — only for a document it could not read at all.
    public enum Failure: Error, Hashable, Sendable {
        /// The blob is there and it is not a replica this package can parse.
        /// Ordinary while the client is halfway through rewriting it, which
        /// is why the stamp is only recorded after a read that worked.
        case unreadable(path: String)
    }

    public let source: SessionSource

    /// The roster slice for this bot's account, when discovery found one.
    /// Read for the name and for `awaitingUserResponse`; there is nothing
    /// else in it this tailer wants.
    public let rosterPath: String?

    private let clock: @Sendable () -> Date
    private let state: Mutex<State>

    private struct State {
        /// Id of the last entry consumed, or `nil` before anything was read.
        var anchor: String?
        /// The next read must adopt what is behind the anchor rather than
        /// emit it, because this tailer was built from a persisted cursor.
        var needsResumeScan: Bool
        /// Entries last seen mid-stream, by id. The one piece of state that
        /// makes a re-read produce a transition rather than a duplicate.
        var streaming: Set<String>
        /// The replica's stamp at the last *successful* read.
        var transcriptStamp: FileStamp?
        /// The roster's stamp at the last read.
        var rosterStamp: FileStamp?
        /// The last `awaitingUserResponse` this tailer announced.
        var awaiting: Bool
        /// The last name this tailer announced, seeded from discovery so a
        /// name discovery already reported is not repeated.
        var title: String?
        /// A turn is open and has not been closed by a `turnEnded` yet.
        var turnOpen: Bool
        /// Monotonic per-tailer event order.
        var sequence: Int64
    }

    /// Creates a tailer over one transcript replica.
    ///
    /// - Parameters:
    ///   - source: The conversation. ``SessionSource/auxiliaryPaths`` carries
    ///     the account's roster slice when discovery found one.
    ///   - cursor: Where to resume. A cursor of another shape — a byte
    ///     offset, a row id — is discarded rather than rejected: a store that
    ///     changed representation should re-seed, not fail.
    ///   - clock: The observation clock, injected for the suite.
    public init(
        source: SessionSource,
        cursor: SourceCursor?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.rosterPath = source.auxiliaryPaths.first
        self.clock = clock
        let anchor = Self.anchor(in: cursor, path: source.primaryPath)
        self.state = Mutex(State(
            anchor: anchor,
            needsResumeScan: anchor != nil,
            streaming: [],
            transcriptStamp: nil,
            rosterStamp: nil,
            awaiting: false,
            title: source.seedIdentity.title,
            turnOpen: false,
            sequence: 0
        ))
    }

    /// The id of the last entry consumed.
    public var cursor: SourceCursor {
        .blobHead(state.withLock { $0.anchor } ?? "")
    }

    /// Entries currently seen mid-stream. Diagnostics and tests only.
    public var streamingCount: Int {
        state.withLock { $0.streaming.count }
    }

    /// The permission id this conversation's *needs you* flag is reported
    /// under. One per bot, so a request and its resolution pair up.
    public var permissionID: String { Self.permissionID(botID: source.key.sessionID) }

    /// `grokbot:<bot uuid>`.
    public static func permissionID(botID: String) -> String { "grokbot:\(botID)" }

    // MARK: - Reading

    /// Everything that changed since the last poll.
    ///
    /// Cheap when nothing moved: two `stat` calls and no parse at all. The
    /// client rewrites this file on every keystroke of a streaming reply, so
    /// the stamp check is what keeps a quiet conversation from costing a JSON
    /// parse per tick.
    public func poll() async throws -> [AgentEvent] {
        try read(seeding: false, limit: nil)
    }

    /// Cold start: the last few entries of the conversation, and nothing
    /// before them.
    ///
    /// `maxBytes` is the caller's budget in the currency of a JSONL
    /// transcript. An entry is a kilobyte or so, so it is spent here as one
    /// entry per kilobyte, bounded either way.
    public func seedFromTail(maxBytes: Int = 64 * 1024) async throws -> [AgentEvent] {
        try read(seeding: true, limit: max(8, min(256, maxBytes / 1024)))
    }

    private func read(seeding: Bool, limit: Int?) throws -> [AgentEvent] {
        let now = clock()
        let transcriptStamp = FileStamp.read(path: source.primaryPath)
        let rosterStamp = rosterPath.flatMap { FileStamp.read(path: $0) }

        // Nothing on disk moved, so nothing can have happened. The client
        // rewrites a replica on every keystroke of a streaming reply, so this
        // is what keeps a quiet conversation costing two `stat` calls rather
        // than a JSON parse per tick.
        let needsTranscript = state.withLock { state in
            seeding || state.needsResumeScan || state.transcriptStamp != transcriptStamp
        }

        var events: [AgentEvent] = []
        if needsTranscript, let transcriptStamp {
            guard let replica = GrokBotStore.replica(at: source.primaryPath) else {
                // Half-written, or not a replica at all. The stamp is left
                // alone so the next poll tries again rather than treating a
                // torn read as the truth.
                throw Failure.unreadable(path: source.primaryPath)
            }
            events += transcriptEvents(
                replica.entries, seeding: seeding, limit: limit, stamp: transcriptStamp, now: now)
        }
        events += rosterEvents(stamp: rosterStamp, now: now)
        guard !events.isEmpty else { return [] }
        return state.withLock { stamped(events, state: &$0) }
    }

    // MARK: - The transcript

    private func transcriptEvents(
        _ entries: [GrokBotEntry],
        seeding: Bool,
        limit: Int?,
        stamp: FileStamp,
        now: Date
    ) -> [AgentEvent] {
        state.withLock { state in
            let resuming = state.needsResumeScan
            let floor = Self.floor(
                entries, anchor: state.anchor, seeding: seeding, limit: limit)

            var events: [AgentEvent] = []
            var spoke = false
            for (index, entry) in entries.enumerated() {
                let isNew = index >= floor
                let wasStreaming = state.streaming.contains(entry.id)

                if !isNew, !wasStreaming {
                    // Consumed and settled before this read. The one thing
                    // worth adopting is an entry that is *still* streaming
                    // across a restart: the conversation genuinely is mid-turn
                    // and a board would otherwise show it idle.
                    if resuming, entry.isStreaming {
                        state.streaming.insert(entry.id)
                        events += mapped(entry, index: index, now: now)
                        spoke = true
                    }
                    continue
                }
                // Still streaming, and it was streaming last time too. The
                // text has grown; the state has not.
                if !isNew, wasStreaming, entry.isStreaming { continue }

                if entry.isStreaming {
                    state.streaming.insert(entry.id)
                } else {
                    state.streaming.remove(entry.id)
                }
                let produced = mapped(entry, index: index, now: now)
                events += produced
                spoke = spoke || produced.contains { Self.opensATurn($0.kind) }
            }

            state.needsResumeScan = false
            state.transcriptStamp = stamp
            if let last = entries.last { state.anchor = last.id }
            if spoke { state.turnOpen = true }

            // The turn closes when the conversation has settled: nothing is
            // streaming, and the newest entry is not a question this bot still
            // owes an answer to. A seed closes it either way — replayed
            // history is history, and a conversation somebody abandoned
            // mid-question should not read as *thinking* a week later.
            let awaitingReply = seeding ? false : (entries.last?.isPrompt ?? false)
            if state.turnOpen, state.streaming.isEmpty, !awaitingReply {
                events.append(AgentEvent(
                    session: source.key,
                    timestamp: entries.last?.timestamp ?? now,
                    observedAt: now,
                    kind: .turnEnded(reason: .complete)
                ))
                state.turnOpen = false
            }
            return events
        }
    }

    private func mapped(_ entry: GrokBotEntry, index: Int, now: Date) -> [AgentEvent] {
        GrokBotEntryMapper.events(
            for: entry,
            session: source.key,
            sourcePath: source.primaryPath,
            index: index,
            now: now
        )
    }

    /// The first entry index this read is allowed to emit from.
    ///
    /// A seed takes the last `limit` entries. Everything else resumes at the
    /// anchor: one past it when it is still in the file, and past the end when
    /// it is not — a replica that lost its anchor is adopted rather than
    /// replayed.
    static func floor(
        _ entries: [GrokBotEntry],
        anchor: String?,
        seeding: Bool,
        limit: Int?
    ) -> Int {
        if seeding {
            return max(0, entries.count - (limit ?? defaultSeedEntries))
        }
        guard let anchor else { return 0 }
        guard let index = entries.firstIndex(where: { $0.id == anchor }) else {
            return entries.count
        }
        return index + 1
    }

    /// Whether an event means the conversation is mid-turn.
    static func opensATurn(_ kind: AgentEventKind) -> Bool {
        switch kind {
        case .userPrompt, .assistantText, .thinking: true
        default: false
        }
    }

    // MARK: - The roster

    /// The `awaitingUserResponse` flip and the bot's name, from the roster
    /// slice beside the replica.
    ///
    /// Stamped with the roster file's own mtime rather than with the
    /// observation clock: that is exactly when the client wrote the flag, and
    /// it is the difference between "a person is needed, since 10:04" and "a
    /// person is needed, since whenever Auspex last looked".
    private func rosterEvents(stamp: FileStamp?, now: Date) -> [AgentEvent] {
        guard let rosterPath, let stamp else { return [] }
        let unchanged = state.withLock { $0.rosterStamp == stamp }
        guard !unchanged else { return [] }

        let rows = GrokBotSessionAdapter.rosterRows(at: URL(fileURLWithPath: rosterPath))
        return state.withLock { state in
            state.rosterStamp = stamp
            guard let row = rows[source.key.sessionID] else { return [] }

            var events: [AgentEvent] = []
            func event(_ kind: AgentEventKind) -> AgentEvent {
                AgentEvent(
                    session: source.key,
                    timestamp: stamp.modified,
                    observedAt: now,
                    kind: kind,
                    raw: RawRef(path: rosterPath)
                )
            }

            if let name = row.name, !name.isEmpty, name != state.title {
                state.title = name
                events.append(event(.identityUpdated(SessionIdentityPatch(title: name))))
            }
            if row.awaitingUserResponse != state.awaiting {
                state.awaiting = row.awaitingUserResponse
                // `allowed: true` because the flag says only that the wait is
                // over. The client does not record whether the person
                // answered or the bot stopped asking, and the reducer needs
                // one of the two to clear the pending request.
                events.append(event(
                    row.awaitingUserResponse
                        ? .permissionRequested(id: permissionID, tool: nil)
                        : .permissionResolved(id: permissionID, allowed: true)
                ))
            }
            return events
        }
    }

    // MARK: - Bookkeeping

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

    /// The entry id inside a cursor, whatever shape it arrived in. An empty
    /// head is what a tailer that never read anything persisted, and it means
    /// the same as no cursor at all.
    static func anchor(in cursor: SourceCursor?, path: String) -> String? {
        switch cursor {
        case let .blobHead(value): value.isEmpty ? nil : value
        case let .composite(members): anchor(in: members[path], path: path)
        case .byteOffset, .rowID, .none: nil
        }
    }
}
