import Foundation

/// Reads new events out of one ``SessionSource``, resuming from a cursor.
///
/// A tailer is stateful and long-lived: it owns the cursor and advances it
/// as it reads. Conforming types are therefore almost always actors —
/// `Sendable` here is a requirement on the conformer, not a promise that a
/// struct will do.
///
/// Two entry points, because a cold start and a steady state need opposite
/// things. ``poll()`` returns everything since the cursor and is called on
/// every filesystem notification, so it must be cheap when nothing changed.
/// ``seedFromTail(maxBytes:)`` is what runs the first time a source is seen:
/// it reads a bounded window from the *end* of the source, so attaching to a
/// machine with a hundred multi-megabyte transcripts costs a hundred small
/// reads rather than a hundred full parses. The current state of a session is
/// near the end of its log; the beginning is history a board does not render.
///
/// Both may return an empty array, and routinely do. Neither may throw on
/// malformed input: a corrupt record is skipped, exactly as in
/// `AgentSessionKit`'s parsers. Throwing is reserved for "could not read the
/// source at all".
public protocol SessionTailer: Sendable {
    /// The source being tailed. Immutable for the tailer's lifetime.
    var source: SessionSource { get }
    /// How far it has read. A host persists this to resume after a relaunch.
    var cursor: SourceCursor { get }

    /// Returns every event after ``cursor`` and advances it past them.
    ///
    /// Throws only when the source cannot be read. Unparseable records are
    /// skipped, and a source that shrank or was replaced re-seeds rather
    /// than reading from a stale offset.
    func poll() async throws -> [AgentEvent]

    /// Cold start: parses at most `maxBytes` from the end of the source and
    /// returns the events found there.
    ///
    /// The window may land mid-record; a tailer discards the partial one at
    /// the front rather than guessing. Events from a seed carry their
    /// source timestamps, which will be old — that is what keeps a replayed
    /// week-old session from being rendered as fresh activity.
    func seedFromTail(maxBytes: Int) async throws -> [AgentEvent]
}
