import Foundation

/// Where events go when the consumer falls behind — and, more importantly,
/// where they do *not*.
///
/// Nothing in the ingest path drops an event. A tailer returns every record
/// it read, and ``IngestCoordinator`` yields every event a tailer returned.
/// The only place a drop can happen is the `AsyncStream` buffering policy the
/// coordinator installs, and it is deliberately the only place: a drop that
/// happens inside a pipeline is invisible, while a drop at a buffer boundary
/// is a property of a named policy a caller can read and change.
///
/// The default is ``defaultEventBufferSize`` events with
/// `.bufferingNewest`, which is the right shape for this data. Events are a
/// *board*, not an archive — a consumer that fell twenty thousand events
/// behind has already lost the plot, and what it needs when it catches up is
/// the present, not the backlog. The full history is still on disk in the
/// harness's own store, reachable through ``RawRef``.
///
/// The consequence a host must design for: after a stall, the reducer may see
/// a `toolCallFinished` whose `toolCallStarted` was dropped. The reducer is
/// total and handles it — an unmatched finish closes nothing and is not an
/// error — but a UI that assumed pairing would be wrong. Re-seeding a session
/// (``SessionTailer/seedFromTail(maxBytes:)``) is how a host recovers a
/// coherent view after a long stall.
///
/// Notices use a much smaller buffer: they are diagnostics, they arrive at
/// human rates, and a host that is not draining them wants the recent ones.
public enum TailerBackpressure {
    /// Events buffered before the oldest are discarded. Roughly a minute of
    /// a very busy machine, or hours of a normal one.
    public static let defaultEventBufferSize = 20_000

    /// Notices buffered before the oldest are discarded.
    public static let defaultNoticeBufferSize = 256
}
