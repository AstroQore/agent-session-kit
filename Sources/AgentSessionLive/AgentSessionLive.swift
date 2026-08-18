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
/// Eight harnesses write eight unrelated formats, and every consumer that
/// learns one of them has to learn all eight. So the target funnels them
/// into one vocabulary and lets everything downstream speak only that:
///
/// ```text
///   store on disk  ──▶  SourceAdapter  ──▶  SessionTailer  ──▶  [AgentEvent]
///                                                                    │
///                          SessionStateReducer  ◀────────────────────┘
///                                    │
///                                    ▼
///                            SessionSnapshot          (one board row)
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
/// What is not here yet: the adapters themselves, the watcher, and the
/// resolver that turns ``LivenessHint``s into `liveness` events. Those land
/// per harness; the protocols they implement are already in place.
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
