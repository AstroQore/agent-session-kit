import Darwin
import Foundation
import Synchronization

/// Where one JSONL record was found, handed to the decoder so it can build a
/// ``RawRef`` back into the source.
///
/// `lineNumber` is 1-based and counts complete lines the *tailer* consumed.
/// It is the file's own line number only when the tailer read from the
/// beginning; a tailer resuming from a persisted cursor or seeded from the
/// tail starts counting at its resume point, because nothing short of
/// re-reading the whole file could recover the absolute number and a
/// transcript is exactly the thing not worth re-reading.
public struct JSONLLineRef: Hashable, Sendable {
    /// The file the line came from.
    public let path: String
    /// Byte offset of the first byte of the line within the file.
    public let byteOffset: Int64
    /// 1-based line count since the tailer started reading. See the type's
    /// discussion for when this is the file's own line number.
    public let lineNumber: Int

    /// Creates a reference.
    public init(path: String, byteOffset: Int64, lineNumber: Int) {
        self.path = path
        self.byteOffset = byteOffset
        self.lineNumber = lineNumber
    }
}

/// Incremental tailing of one append-only JSONL file, resuming from a byte
/// offset and re-seeding when the file underneath it changed identity.
///
/// Generic on purpose: nothing here knows what a Claude Code transcript line
/// or a Codex rollout item looks like. A per-harness adapter supplies a
/// `decode` closure that turns one line's bytes into zero or more
/// ``AgentEvent``s, and inherits rotation handling, partial-line buffering,
/// cold-start seeding, and cursor bookkeeping for free. Six of the eight
/// harnesses write JSONL; writing that logic six times is how the sixth one
/// ends up subtly different.
///
/// ## What it defends against
///
/// - **A half-written line.** A harness appends a record with one `write(2)`
///   and the tailer can still observe the file mid-write. A line is decoded
///   only once its terminating newline has arrived; until then the bytes sit
///   in a buffer and the cursor stays behind them.
/// - **Truncation.** A file shorter than where the cursor is pointing was
///   rewritten. The tailer resets to zero rather than reading from an offset
///   that now lands in the middle of a different record.
/// - **Rotation.** A different inode at the same path is a different file,
///   whatever it is called. Same reset.
/// - **Disappearance.** A source that is not there right now returns no
///   events and keeps its cursor. Harnesses move files between directories,
///   and a board that dropped a session because of a `rename(2)` would be
///   wrong for the fraction of a second the rename took.
/// - **Garbage.** A line the decoder cannot make sense of yields no events
///   and does not stop the walk. Non-UTF-8 bytes never reach a `String`
///   here: the decoder is handed `Data`.
///
/// ## Cursor semantics
///
/// ``cursor`` is always `.byteOffset(inode:offset:)` where `offset` is the
/// position just past the last *complete* line consumed. A host may persist
/// it at any time; a tailer built with it resumes exactly there, and the
/// partial line the previous run was holding is simply read again.
public final class JSONLTailer: SessionTailer {
    /// Bytes per read. Matches `JSONLLineScanner`, for the same reason:
    /// transcripts reach hundreds of megabytes and a whole-file read is
    /// neither bounded nor linear.
    public static let chunkSize = 64 * 1024

    /// The default cold-start window. Large enough to carry the last turn of
    /// a busy session, small enough that a hundred sources cost a few
    /// megabytes of reading rather than a few gigabytes.
    public static let defaultSeedBytes = 64 * 1024

    /// Reasons a tailer gives up on a read. Never thrown for bad content —
    /// only for a source that could not be read at all.
    public enum Failure: Error, Hashable, Sendable {
        /// The file exists but could not be opened.
        case cannotOpen(path: String)
        /// A read or seek failed part-way through.
        case readFailed(path: String)
    }

    public let source: SessionSource

    /// The file this tailer reads — ``SessionSource/primaryPath`` unless the
    /// caller pointed it somewhere else.
    public let path: String

    private let decode: @Sendable (Data, JSONLLineRef) -> [AgentEvent]
    private let state: Mutex<State>

    private struct State {
        /// Inode the offset was taken in. `0` means "nothing read yet".
        var inode: UInt64
        /// Position just past the last complete line consumed.
        var offset: Int64
        /// Bytes read past `offset` that have no terminating newline yet.
        var pending: [UInt8]
        /// Complete lines consumed since this tailer started reading.
        var lineNumber: Int
        /// Monotonic per-tailer event order.
        var sequence: Int64
    }

    /// Creates a tailer over `path`.
    ///
    /// - Parameters:
    ///   - source: The session this file belongs to. Only carried, never
    ///     interpreted.
    ///   - path: The file to read. Defaults to the source's primary path,
    ///     which is what every single-file harness wants; a multi-file
    ///     harness builds one tailer per path and composes the cursors.
    ///   - cursor: Where to resume. A cursor of the wrong shape — a row id,
    ///     a blob head — is discarded rather than rejected, because a store
    ///     that changed representation should re-seed, not fail. A
    ///     `.composite` cursor is looked up by `path`.
    ///   - decode: Turns one line's bytes into events. Returning `[]` is how
    ///     a record that is not interesting, or not parseable, is skipped.
    ///     Events that come back with no ``AgentEvent/raw`` get one built
    ///     from the line reference.
    public init(
        source: SessionSource,
        path: String? = nil,
        cursor: SourceCursor? = nil,
        decode: @escaping @Sendable (Data, JSONLLineRef) -> [AgentEvent]
    ) {
        self.source = source
        self.path = path ?? source.primaryPath
        self.decode = decode
        let resolved = Self.resume(from: cursor, path: path ?? source.primaryPath)
        self.state = Mutex(
            State(
                inode: resolved.inode,
                offset: resolved.offset,
                pending: [],
                lineNumber: 0,
                sequence: 0
            )
        )
    }

    public var cursor: SourceCursor {
        state.withLock { .byteOffset(inode: $0.inode, offset: $0.offset) }
    }

    /// How many complete lines this tailer has consumed. Diagnostics only.
    public var linesConsumed: Int {
        state.withLock { $0.lineNumber }
    }

    /// Reads everything appended since ``cursor`` and advances it.
    ///
    /// Cheap when nothing changed: one `stat`, and a `read` that returns
    /// nothing. Not `async` — the work is a bounded file read, and a caller
    /// that must not block should run it off its own executor, which is what
    /// ``IngestCoordinator`` does.
    public func poll() throws -> [AgentEvent] {
        try state.withLock { try readForward(&$0) }
    }

    /// Cold start: reads at most `maxBytes` from the end of the file.
    ///
    /// The window almost always opens in the middle of a record; that first
    /// partial line is discarded rather than guessed at. Afterwards the
    /// cursor sits at the end of the last complete line, so the very next
    /// ``poll()`` returns only what was appended after the seed.
    ///
    /// Events keep whatever timestamps the decoder read out of the source —
    /// which for a week-old transcript are a week old. A decoder should set
    /// ``AgentEvent/observedAt`` to now so that replayed history is not
    /// rendered as fresh activity.
    public func seedFromTail(maxBytes: Int = JSONLTailer.defaultSeedBytes) throws -> [AgentEvent] {
        try state.withLock { state in
            guard let stamp = FileStamp.read(path: path) else {
                // Nothing to seed from. Keep whatever cursor we had; the
                // file may be back before the next poll.
                return []
            }

            let window = Int64(max(0, maxBytes))
            let start = max(0, stamp.size - window)

            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw Failure.cannotOpen(path: path)
            }
            defer { try? handle.close() }
            var bytes: [UInt8]
            do {
                try handle.seek(toOffset: UInt64(start))
                bytes = [UInt8](try handle.readToEnd() ?? Data())
            } catch {
                throw Failure.readFailed(path: path)
            }

            state.inode = stamp.inode
            state.lineNumber = 0
            state.pending = []

            // The window opens mid-record unless it happened to land right
            // after a newline. Drop that fragment rather than guess at it.
            var base = start
            if start > 0 {
                if let newline = bytes.firstIndex(of: 0x0A) {
                    bytes.removeFirst(newline + 1)
                    base += Int64(newline + 1)
                } else {
                    // The whole window is one unterminated fragment. There is
                    // nothing decodable in it; start from the end.
                    base = start + Int64(bytes.count)
                    bytes = []
                }
            }

            var events: [AgentEvent] = []
            var lineStart = 0
            consumeLines(
                buffer: bytes,
                lineStart: &lineStart,
                bufferStart: base,
                state: &state,
                events: &events
            )
            state.offset = base + Int64(lineStart)
            state.pending = lineStart < bytes.count ? Array(bytes[lineStart...]) : []
            return events
        }
    }

    // MARK: - Reading

    /// Reads from the current offset to EOF, resetting first if the file was
    /// replaced or truncated.
    private func readForward(_ state: inout State) throws -> [AgentEvent] {
        guard let stamp = FileStamp.read(path: path) else { return [] }

        if state.inode == 0 {
            state.inode = stamp.inode
        } else if stamp.inode != state.inode {
            // Rotation: a different file wears the same name.
            state.inode = stamp.inode
            state.offset = 0
            state.pending = []
            state.lineNumber = 0
        }

        let consumed = state.offset + Int64(state.pending.count)
        if stamp.size < consumed {
            // Truncation or rewrite: the bytes we were counting on are gone.
            state.offset = 0
            state.pending = []
            state.lineNumber = 0
        } else if stamp.size == consumed {
            return []
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            // It was there for the `stat` and gone by the `open`. Not an
            // error worth propagating: the next poll will find it or not.
            return []
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(state.offset + Int64(state.pending.count)))
        } catch {
            throw Failure.readFailed(path: path)
        }
        return try drain(handle: handle, into: &state)
    }

    /// Consumes the handle to EOF, decoding every complete line and leaving
    /// any trailing fragment in `state.pending`.
    private func drain(handle: FileHandle, into state: inout State) throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        var buffer = state.pending
        // Byte offset in the file of `buffer[0]`.
        var bufferStart = state.offset
        var lineStart = 0

        do {
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                buffer.append(contentsOf: chunk)
                consumeLines(
                    buffer: buffer,
                    lineStart: &lineStart,
                    bufferStart: bufferStart,
                    state: &state,
                    events: &events
                )
                // Only compact once a whole chunk has been consumed, so the
                // walk stays linear: `Array.removeFirst` shifts bytes, and
                // shifting after every line is how an O(n) scan becomes
                // O(n²) on a transcript with a million of them.
                if lineStart > Self.chunkSize {
                    buffer.removeFirst(lineStart)
                    bufferStart += Int64(lineStart)
                    lineStart = 0
                }
            }
        } catch {
            throw Failure.readFailed(path: path)
        }

        // Whatever is left has no newline yet. Hold it, and leave the cursor
        // in front of it so a persisted cursor never points mid-record.
        state.offset = bufferStart + Int64(lineStart)
        state.pending = lineStart < buffer.count ? Array(buffer[lineStart...]) : []
        return events
    }

    /// Decodes every complete line in `buffer` at or after `lineStart`,
    /// advancing `lineStart` past the last newline it saw.
    ///
    /// Empty lines are skipped without calling the decoder — a trailing
    /// newline is not a record, and several harnesses write one.
    private func consumeLines(
        buffer: [UInt8],
        lineStart: inout Int,
        bufferStart: Int64,
        state: inout State,
        events: inout [AgentEvent]
    ) {
        var index = lineStart
        while index < buffer.count {
            if buffer[index] == 0x0A {
                if index > lineStart {
                    state.lineNumber += 1
                    let reference = JSONLLineRef(
                        path: path,
                        byteOffset: bufferStart + Int64(lineStart),
                        lineNumber: state.lineNumber
                    )
                    for event in decode(Data(buffer[lineStart..<index]), reference) {
                        state.sequence += 1
                        events.append(stamped(event, sequence: state.sequence, reference: reference))
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
    }

    /// Applies the tailer's own bookkeeping to a decoded event: a monotonic
    /// sequence, and a ``RawRef`` when the decoder did not supply one.
    private func stamped(_ event: AgentEvent, sequence: Int64, reference: JSONLLineRef) -> AgentEvent {
        AgentEvent(
            id: event.id,
            session: event.session,
            timestamp: event.timestamp,
            observedAt: event.observedAt,
            sequence: sequence,
            kind: event.kind,
            raw: event.raw ?? RawRef(
                path: reference.path,
                byteOffset: reference.byteOffset,
                lineNumber: reference.lineNumber
            )
        )
    }

    /// Extracts an `(inode, offset)` pair from a persisted cursor, or
    /// `(0, 0)` when there is nothing usable in it.
    private static func resume(from cursor: SourceCursor?, path: String) -> (inode: UInt64, offset: Int64) {
        switch cursor {
        case let .byteOffset(inode, offset):
            return (inode, max(0, offset))
        case let .composite(parts):
            return resume(from: parts[path], path: path)
        case .rowID, .blobHead, .none:
            return (0, 0)
        }
    }
}
