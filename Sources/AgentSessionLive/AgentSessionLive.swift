import AgentSessionKit
import Foundation

/// Live views over the stores `AgentSessionKit` reads.
///
/// `AgentSessionKit` answers "what is on disk right now": one pass, one
/// snapshot, no observers. This target answers the other question — "tell me
/// when it changes" — and that needs different trade-offs: watches over the
/// provider roots, debouncing (a CLI rewrites a rollout many times a second
/// while a turn streams), incremental tailing that resumes from a cursor
/// instead of re-reading a transcript, and a WAL-aware poll for the stores
/// another process keeps open.
///
/// ## The shape of it
///
/// Nine harnesses write nine unrelated formats, and every consumer that
/// learns one of them has to learn all nine. So the target funnels them
/// into one vocabulary and lets everything downstream speak only that:
///
/// ```text
///                       ┌───────────────── IngestCoordinator ─────────────────┐
///  SourceAdapter        │                                                     │
///   .watchRoots ────────┼──▶ FSEventsWatcher ──▶ debounce 50 ms / 250 ms ──┐  │
///   .discover ──────────┼──▶ SessionSource ──▶ SessionTailer.poll() ◀──────┤  │
///     every 15 s        │         ▲                    ▲   safety-net poll │  │
///   .makeTailer ────────┼─────────┘                    └── 2 s / 10 s ──────┘  │
///                       │              SourceCursorStore (resume; save 2 s)   │
///                       └────────────────────────┬────────────────────────────┘
///                                                ▼
///                              AsyncStream<AgentEvent>   AsyncStream<IngestNotice>
///                                                │
///                          SessionStateReducer ◀─┘
///                                    │
///                                    ▼
///                            SessionSnapshot          (one board row)
///
///  ProcessTable ──▶ SourceAdapter.probeLiveness ──▶ LivenessResolver
///       │                                                │  transitions only
///       │                    AgentEventKind.liveness  ◀───┘
///       └──▶ ProcessLinker ──▶ ProcessLink ──▶ AgentEventKind.identityUpdated
/// ```
///
/// - ``SessionKey`` names a session globally: a harness plus that harness's
///   own id, since ids collide across trees.
/// - ``AgentEvent`` is one observed fact. Its ``AgentEventKind`` is the whole
///   vocabulary — prompts, turns, tool calls, permissions, subagents, usage,
///   liveness — and a case exists only where a real store records the fact.
/// - ``SessionStateReducer`` folds events into a ``SessionSnapshot``: derived
///   state, what is still open, counters, tokens, children. Pure, total, and
///   the only thing in the target that decides what a session "is doing".
/// - ``SessionIdentity`` accretes separately from state, through sparse
///   ``SessionIdentityPatch`` updates, because evidence about *what* a
///   session is arrives long after evidence about what it is doing.
///
/// ## Ingest
///
/// ``IngestCoordinator`` is the only thing a host starts. It owns one
/// ``FSEventsWatcher`` over the union of every adapter's roots, a
/// ``SessionTailer`` per discovered source, a debounce in front of each
/// tailer, a safety-net poll behind it, and a rediscovery pass that notices
/// sessions that did not exist when it started. ``JSONLTailer`` is the
/// building block six of the nine harnesses share: an adapter supplies a
/// line decoder and inherits rotation handling, partial-line buffering, and
/// cold-start seeding. ``SQLiteChangeWatcher`` covers the two that keep a
/// database open instead, where the file that moves during a turn is the
/// `-wal` and not the `.db`.
///
/// ## Liveness
///
/// The one fact no log records. ``ProcessTable`` reads `libproc` and
/// `sysctl`, ``LockFileProbe`` asks the kernel who holds a file lock, and
/// ``LivenessResolver`` combines each adapter's own probe with a generic
/// `(pid, startTime)` check — pids are recycled, so the pair is the identity —
/// and emits ``AgentEventKind/liveness(alive:)`` only when the answer
/// changed.
///
/// ## Linking
///
/// The same process table answers a second question no log records: which
/// session started which. ``ProcessLinker`` reads the environment a harness
/// hands its children — the variables are tabulated once in
/// ``SessionEnvironmentVariables`` — and, failing that, the spawn tree, and
/// proposes ``ProcessLink`` edges a host applies as identity patches. It only
/// ever fills a blank: ``ParentLink/precedence`` ranks a person's own link and
/// a logged spawn above anything inferred here.
///
/// What is not here yet: Gemini CLI, whose `~/.gemini/tmp/*/chats` the
/// on-disk index reads and nothing tails. Every other harness has an adapter.
///
/// Built in the Swift 6 language mode. `AgentSessionKit` is still on Swift 5
/// while its adapters are migrated.
public enum AgentSessionLive {
    /// Version of the event and snapshot model.
    ///
    /// A host that persists ``AgentEvent`` or ``SessionSnapshot`` rows stamps
    /// them with this and re-seeds rather than decoding rows from a model it
    /// no longer speaks. Bumped whenever a case is added to
    /// ``AgentEventKind`` or a field to ``SessionSnapshot``, because both are
    /// encoded structurally.
    public static let eventSchemaVersion = 1
}
