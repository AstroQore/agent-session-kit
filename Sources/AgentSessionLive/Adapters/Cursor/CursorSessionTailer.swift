import AgentSessionKit
import Foundation
import Synchronization

/// How far a tailer has read into a Cursor store, as a string a
/// ``SourceCursor/blobHead(_:)`` can carry.
///
/// `"<root blob id>|<anchor>"`, where the anchor is the
/// ``CursorMessageRef/anchor`` of the last message already emitted. Both
/// halves are needed and neither is redundant:
///
/// - The **root** is the cheap question. It changes once per turn, so a poll
///   that finds it unchanged returns without fetching a single blob.
/// - The **anchor** is the resume point. After a relaunch the in-memory set of
///   visited blobs is gone, and the only way back to "where was I" is to walk
///   the graph and find the message that was last emitted. That works because
///   the store is content-addressed: a written message can never move, change,
///   or be renumbered, so its id is a stable position in the conversation.
///
/// Persisting the whole visited set instead would be one 64-character id per
/// blob — tens of kilobytes for a long conversation, in a file a host rewrites
/// on every tick. Persisting only the root would be cheaper still and wrong:
/// the graph's shape does not guarantee the previous root stays reachable from
/// the new one, so "walk until you meet the old head" is not a stop condition
/// that can be relied on. The anchor needs no such guarantee.
struct CursorStoreCursor: Hashable, Sendable {
    /// The head blob the last walk processed.
    let root: String
    /// The anchor of the last message emitted, or `nil` when the walk reached
    /// no messages at all.
    let anchor: String?

    /// Separates the two halves. Blob ids are hex, so it cannot occur in one.
    static let separator: Character = "|"

    /// The persisted form.
    var encoded: String {
        guard let anchor else { return root }
        return "\(root)\(Self.separator)\(anchor)"
    }

    /// Parses the persisted form. A string with no separator is a root with
    /// no anchor, which is what a conversation whose only turn was empty
    /// leaves behind.
    static func decode(_ raw: String) -> CursorStoreCursor? {
        guard !raw.isEmpty else { return nil }
        guard let separator = raw.firstIndex(of: Self.separator) else {
            return CursorStoreCursor(root: raw, anchor: nil)
        }
        let root = String(raw[raw.startIndex..<separator])
        let anchor = String(raw[raw.index(after: separator)...])
        guard !root.isEmpty else { return nil }
        return CursorStoreCursor(root: root, anchor: anchor.isEmpty ? nil : anchor)
    }

    /// Pulls the store's half out of whatever a host persisted.
    ///
    /// A cursor of the wrong shape — a byte offset, a row id — is discarded
    /// rather than rejected, exactly as ``JSONLTailer`` discards one: a store
    /// that changed representation should re-seed, not fail.
    static func extract(from cursor: SourceCursor?, path: String) -> CursorStoreCursor? {
        switch cursor {
        case let .blobHead(raw):
            return decode(raw)
        case let .composite(parts):
            return extract(from: parts[path], path: path)
        case .byteOffset, .rowID, .none:
            return nil
        }
    }
}

/// The incremental half of a Cursor tail: the blob graph, walked once per
/// change of `latestRootBlobId`.
///
/// Stateful and self-contained, so ``CursorSessionTailer`` can compose it with
/// an ordinary ``JSONLTailer`` without either knowing about the other.
///
/// Three shapes of read, in descending order of how often they happen:
///
/// 1. **The root is unchanged.** One small query against `meta`, no blob
///    fetched, no JSON parsed. This is what almost every poll does.
/// 2. **The root moved and the walk is primed.** Breadth-first from the new
///    root with the previous visit set in hand, so only genuinely new blobs
///    are fetched, and only the new messages are parsed.
/// 3. **The root moved and the walk is not primed** — the first change after
///    a relaunch. The graph is walked whole to find the anchor, but only the
///    messages past it are parsed. One full traversal per process lifetime,
///    not per poll.
final class CursorStoreWalker: Sendable {
    /// The store being walked.
    let reader: CursorStoreReader
    /// The key events are attributed to.
    let session: SessionKey
    /// Whether this half owns ``AgentEventKind/userPrompt(preview:)`` — true
    /// exactly when the session has no thin transcript to own it instead.
    let emitsUserPrompt: Bool

    private let clock: @Sendable () -> Date
    private let state: Mutex<State>

    private struct State {
        /// The head blob the last walk processed.
        var root: String?
        /// The anchor of the last message emitted.
        var anchor: String?
        /// Every blob id a walk in *this* process has fetched.
        var seen: Set<String>
        /// Whether ``seen`` reflects a complete walk. `false` after a resume
        /// from a persisted cursor, until the first walk repopulates it.
        var primed: Bool
        /// The last model reported, so a patch is emitted on a change rather
        /// than on every assistant message.
        var model: String?
    }

    init(
        reader: CursorStoreReader,
        session: SessionKey,
        cursor: CursorStoreCursor?,
        emitsUserPrompt: Bool,
        clock: @escaping @Sendable () -> Date
    ) {
        self.reader = reader
        self.session = session
        self.emitsUserPrompt = emitsUserPrompt
        self.clock = clock
        self.state = Mutex(
            State(root: cursor?.root, anchor: cursor?.anchor, seen: [], primed: false, model: nil)
        )
    }

    /// The store's half of the composite cursor, or `nil` before anything has
    /// been read.
    var cursor: SourceCursor? {
        state.withLock { state in
            guard let root = state.root else { return nil }
            return .blobHead(CursorStoreCursor(root: root, anchor: state.anchor).encoded)
        }
    }

    /// Everything written since the cursor.
    ///
    /// Returns `[]` — without touching a blob — whenever `latestRootBlobId` is
    /// what it was, which is every poll but the one that follows a turn.
    func poll() -> [AgentEvent] {
        guard let root = reader.readMeta()?.latestRootBlobID, !root.isEmpty else { return [] }
        return state.withLock { state in
            guard state.root != root else { return [] }

            let walk = reader.walk(from: root, seen: state.primed ? state.seen : [])
            var fresh = walk.messages
            if !state.primed, let anchor = state.anchor {
                if let index = fresh.firstIndex(where: { $0.anchor == anchor }) {
                    fresh = Array(fresh[fresh.index(after: index)...])
                }
                // The anchor is gone: the store was rewritten or compacted
                // under us. Replaying what is there beats losing it, and it is
                // the same choice `JSONLTailer` makes when a file it was
                // reading turns out to have been replaced.
            }

            if state.primed {
                state.seen.formUnion(walk.visited)
            } else {
                state.seen = Set(walk.visited)
            }
            state.primed = true
            state.root = root
            if let last = walk.messages.last { state.anchor = last.anchor }

            return events(reader.decode(fresh), state: &state)
        }
    }

    /// Cold start: the last `limit` messages of the conversation.
    ///
    /// The graph still has to be traversed whole — the *last* message is only
    /// knowable from the end — but the traversal parses nothing, so the cost
    /// is one point lookup per blob and one JSON parse per message actually
    /// returned.
    func seed(messages limit: Int) -> [AgentEvent] {
        guard let root = reader.readMeta()?.latestRootBlobID, !root.isEmpty else { return [] }
        return state.withLock { state in
            let walk = reader.walk(from: root, seen: [])
            let tail = Array(walk.messages.suffix(max(0, limit)))

            state.seen = Set(walk.visited)
            state.primed = true
            state.root = root
            // The anchor is the end of the conversation, not the end of the
            // window: the messages before it were skipped on purpose and must
            // not come back on the next poll.
            state.anchor = walk.messages.last?.anchor

            return events(reader.decode(tail), state: &state)
        }
    }

    /// Maps decoded messages, dropping a model patch that says what the last
    /// one already did.
    private func events(_ messages: [CursorMessage], state: inout State) -> [AgentEvent] {
        let now = clock()
        var out: [AgentEvent] = []
        for message in messages {
            for event in CursorMessageMapper.events(
                from: message, session: session, now: now, emitsUserPrompt: emitsUserPrompt
            ) {
                if case let .identityUpdated(patch) = event.kind, let model = patch.model {
                    guard model != state.model else { continue }
                    state.model = model
                }
                out.append(event)
            }
        }
        return out
    }
}

/// One Cursor agent, tailed: the store's blob graph and — when a
/// `cursor-agent` CLI wrote one — the thin transcript beside it.
///
/// ## Why two sources
///
/// Neither file is enough on its own. The store has the tool calls, the
/// reasoning, the model, and the full text of everything; it has no notion of
/// a turn ending. The thin transcript has turn boundaries and nothing else —
/// no tool calls at all. So the composite reads both and each owns the facts
/// it is the authority on:
///
/// | Fact | Owner |
/// | --- | --- |
/// | `userPrompt` (opens a turn) | thin transcript, or the store when there is none |
/// | `turnEnded` | thin transcript only |
/// | `textBody(.user, …)` | store |
/// | `assistantText`, `thinking`, `textBody(.assistant, …)` | store |
/// | `toolCallStarted` / `toolCallFinished` / `textBody(.toolResult, …)` | store |
/// | `identityUpdated(model:)` | store |
///
/// An agent started inside the IDE has no thin transcript, and then the store
/// owns `userPrompt` too — set by ``CursorLiveAdapter`` when it builds the
/// source, so the mapper stays pure and the decision is made once.
///
/// ## Ordering within a poll
///
/// Store events first, thin-transcript events last. A poll that happens to
/// span a whole turn therefore ends on the transcript's own last line, which
/// is the one that says whether the turn closed — leaving the reducer in the
/// state the session is actually in rather than in the middle of the body it
/// just replayed. In a live tail the question rarely arises: a turn spans many
/// polls, and each source's events arrive in the poll that saw them.
public final class CursorSessionTailer: SessionTailer {
    /// Bytes of a cold-start window that buy one message of store history.
    ///
    /// The `maxBytes` in ``seedFromTail(maxBytes:)`` is a file-shaped budget
    /// and the store is not a file, so it is converted rather than ignored: a
    /// Cursor message with its parts is a couple of kilobytes, and the default
    /// 64 KiB window therefore seeds about thirty of them — the last turn or
    /// two, which is what a board renders.
    public static let bytesPerMessage = 2 * 1024

    /// Ceiling on a seed however large the window is. Beyond this a "cold
    /// start" is a replay of the whole conversation.
    public static let maxSeedMessages = 200

    public let source: SessionSource

    private let storePath: String
    private let store: CursorStoreWalker
    private let transcript: JSONLTailer?
    private let sequence: Mutex<Int64>

    /// Creates a tailer.
    ///
    /// - Parameters:
    ///   - source: The session. ``SessionSource/primaryPath`` is the
    ///     `store.db`; the thin transcript, when there is one, is the `.jsonl`
    ///     in ``SessionSource/auxiliaryPaths``.
    ///   - cursor: Where to resume, `nil` for a cold start.
    ///   - clock: The observation clock, injected so the suite does not have
    ///     to wait for real time to pass.
    public init(
        source: SessionSource,
        cursor: SourceCursor?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.storePath = source.primaryPath
        let transcriptPath = source.auxiliaryPaths.first { $0.hasSuffix(".jsonl") }
        let key = source.key

        self.store = CursorStoreWalker(
            reader: CursorStoreReader(path: source.primaryPath),
            session: key,
            cursor: CursorStoreCursor.extract(from: cursor, path: source.primaryPath),
            emitsUserPrompt: transcriptPath == nil,
            clock: clock
        )
        self.transcript = transcriptPath.map { path in
            JSONLTailer(source: source, path: path, cursor: cursor) { data, _ in
                CursorThinTranscriptMapper.events(from: data, session: key, now: clock())
            }
        }
        self.sequence = Mutex(0)
    }

    /// The store's blob head and the transcript's byte offset, keyed by path.
    ///
    /// Always `.composite`, even for a session with only a store: a source
    /// that grows a thin transcript later must not need a different cursor
    /// shape, and an empty dictionary round-trips as cleanly as a full one.
    public var cursor: SourceCursor {
        var parts: [String: SourceCursor] = [:]
        if let head = store.cursor { parts[storePath] = head }
        if let transcript { parts[transcript.path] = transcript.cursor }
        return .composite(parts)
    }

    public func poll() throws -> [AgentEvent] {
        let events = store.poll() + (try transcript?.poll() ?? [])
        return stamped(events)
    }

    public func seedFromTail(maxBytes: Int) throws -> [AgentEvent] {
        let events = store.seed(messages: Self.seedMessages(forBytes: maxBytes))
            + (try transcript?.seedFromTail(maxBytes: maxBytes) ?? [])
        return stamped(events)
    }

    /// How many store messages a byte-shaped seed window is worth.
    public static func seedMessages(forBytes maxBytes: Int) -> Int {
        guard maxBytes > 0 else { return 0 }
        return max(1, min(maxSeedMessages, maxBytes / bytesPerMessage))
    }

    /// Applies one monotonic order across both halves, and gives a store event
    /// a reference back to the database it came from.
    ///
    /// The composite has to own the sequence: each half counts its own, and
    /// two independent counters would collide on every poll that read both.
    private func stamped(_ events: [AgentEvent]) -> [AgentEvent] {
        sequence.withLock { counter in
            events.map { event in
                counter += 1
                return AgentEvent(
                    id: event.id,
                    session: event.session,
                    timestamp: event.timestamp,
                    observedAt: event.observedAt,
                    sequence: counter,
                    kind: event.kind,
                    // The store is content-addressed: there is no offset and
                    // no row id to point at, only the database itself.
                    raw: event.raw ?? RawRef(path: storePath)
                )
            }
        }
    }
}
