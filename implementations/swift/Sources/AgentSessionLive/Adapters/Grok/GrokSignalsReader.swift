import AgentSessionKit
import Foundation
import Synchronization

/// Reads the one thing in `signals.json` that is a level rather than a running
/// total: how much of the context window the conversation occupies.
///
/// Grok Build is the only harness here that computes its own `/context` gauge
/// and writes the answer down — `contextTokensUsed` out of
/// `contextWindowTokens` — so there is nothing to derive and no model table to
/// consult. What the file does not have is a *timeline*: it is rewritten in
/// place, so there is no cursor to advance and no history to replay, only a
/// current value and the mtime it was written at.
///
/// That is why this is not a ``JSONLTailer``. It stats the file on every poll
/// and parses it only when the stamp moved, so a poll that changes nothing
/// costs one `stat(2)` — cheap enough to ride along inside
/// ``GrokSessionTailer`` without a watch of its own. `signals.json` stays out
/// of ``GrokLiveAdapter/mightBeSessionFile(path:)`` and out of the source's
/// auxiliary paths for exactly the reason it always did: Grok rewrites it many
/// times a minute, and a host waking on every rewrite is the storm that rule
/// exists to prevent. The session's own logs move whenever this file does, and
/// the poll they trigger reads it anyway.
///
/// The other counters in the file are deliberately left alone. Turns, tool
/// calls, and compactions each have a record of their own in `events.jsonl`,
/// and ``SessionStateReducer`` builds its counts from those; folding a running
/// total in beside them would double what was already counted.
final class GrokSignalsReader: Sendable {
    /// The file's name inside a session directory.
    static let fileName = "signals.json"

    /// The file this reads.
    let path: String

    private let session: SessionKey
    /// The stamp of the last version that was parsed. `nil` until the first
    /// read, which is what makes a cold start report the current level.
    private let lastRead: Mutex<FileStamp?>

    /// Creates a reader over one session directory.
    init(directory: URL, session: SessionKey) {
        self.path = directory.appendingPathComponent(Self.fileName).path
        self.session = session
        self.lastRead = Mutex(nil)
    }

    /// The context reading, or `[]` when the file has not changed since the
    /// last call, cannot be read, or records no context counters.
    ///
    /// Stamped with the file's own mtime rather than with `now`, so the merge
    /// in ``GrokSessionTailer`` orders it against the log lines it arrived
    /// beside, and so a session picked up cold does not report a week-old
    /// level as something that just happened.
    func poll(now: Date) -> [AgentEvent] {
        guard let stamp = FileStamp.read(path: path) else { return [] }
        let changed = lastRead.withLock { previous -> Bool in
            guard previous != stamp else { return false }
            previous = stamp
            return true
        }
        guard changed,
              let signals = GrokSignals.read(path: path),
              let used = signals.contextTokensUsed
        else { return [] }

        return [
            AgentEvent(
                session: session,
                timestamp: stamp.modified,
                observedAt: now,
                kind: .contextUsage(
                    used: used,
                    window: signals.contextWindowTokens,
                    // The harness records no cached share. A `nil` says so;
                    // zero would claim it measured one and found none.
                    cached: nil,
                    source: .measured
                )
            )
        ]
    }
}
