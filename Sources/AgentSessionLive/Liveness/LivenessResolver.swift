import AgentSessionKit
import Foundation

/// Turns process-table evidence into ``AgentEventKind/liveness(alive:)``
/// events, and emits one only when the answer changed.
///
/// Liveness is the one fact about a session that no log records. A transcript
/// ends identically whether the harness exited cleanly, was killed, or is
/// still thinking, so the only way to tell is to look at what is running —
/// which is a different kind of evidence, arriving on a different schedule,
/// and it gets its own component rather than being smuggled into a tailer.
///
/// ## Two probes, and which one wins
///
/// Each adapter answers for its own harness through
/// ``SourceAdapter/probeLiveness(_:table:home:)``, because the evidence is
/// harness-shaped: Codex holds a writer lock, Claude Code's pid is in its
/// transcript, Cursor has no process of its own at all and honestly answers
/// ``LivenessHint/Verdict/unknown``.
///
/// On top of that sits a generic check: if the identity carries a pid, is
/// that pid running, and is it the *same* process it was? Pids are recycled
/// within hours on a busy machine, so `(pid, startTime)` is the identity and
/// a start time more than ``tolerance`` away from the recorded one means the
/// original process is gone and something else moved in.
///
/// The two combine by a rule that is deliberately pessimistic in one
/// direction only:
///
/// - Adapter says `unknown` → the generic check answers.
/// - Adapter says `alive` but the generic check proves the pid is gone or
///   recycled → **dead**. An adapter can be optimistic about its own store;
///   it cannot out-vote the kernel about a pid.
/// - Otherwise the adapter's answer stands.
///
/// ## Transitions only
///
/// ``runLoop(every:identities:into:)`` emits nothing while an answer stays
/// the same. A board with sixty sessions ticking every three seconds would
/// otherwise produce twenty events a second that all say what the last one
/// said, and every one of them would touch the reducer, the store, and the
/// diffable UI list. `unknown` is not a transition either: it means the probe
/// learned nothing, and overwriting a known state with it would make a live
/// session flicker.
public actor LivenessResolver {
    /// How far a process's start time may differ from the recorded one
    /// before the pid is considered recycled.
    public let tolerance: TimeInterval

    private let adapters: [Harness: any SourceAdapter]
    private let table: any ProcessTableReading
    private let home: String
    private var lastKnown: [SessionKey: Bool] = [:]

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - adapters: One per harness. Where two adapters claim the same
    ///     harness the first wins; a probe is per-harness by construction.
    ///   - table: The process table. Injected so the suite can drive every
    ///     branch off a fixed list instead of whatever is running.
    ///   - home: Passed through to each adapter's probe.
    ///   - tolerance: Start-time slack for the recycled-pid check. Two
    ///     seconds covers the gap between a harness starting and the
    ///     transcript line that records when it thought it started.
    public init(
        adapters: [any SourceAdapter],
        table: any ProcessTableReading,
        home: String,
        tolerance: TimeInterval = 2
    ) {
        var byHarness: [Harness: any SourceAdapter] = [:]
        for adapter in adapters where byHarness[adapter.harness] == nil {
            byHarness[adapter.harness] = adapter
        }
        self.adapters = byHarness
        self.table = table
        self.home = home
        self.tolerance = tolerance
    }

    /// Probes every identity and returns one hint each.
    ///
    /// Pure with respect to the process table, and every identity in one call
    /// sees the same snapshot of it — ``ProcessTable`` caches, so a hundred
    /// probes cost one read.
    public func resolve(_ identities: [SessionIdentity]) -> [SessionKey: LivenessHint] {
        var out: [SessionKey: LivenessHint] = [:]
        out.reserveCapacity(identities.count)
        for identity in identities {
            out[identity.key] = hint(for: identity)
        }
        return out
    }

    /// The combined hint for one identity. See the type's discussion of how
    /// the adapter's answer and the generic pid check are reconciled.
    public func hint(for identity: SessionIdentity) -> LivenessHint {
        let adapterHint = adapters[identity.key.harness]?
            .probeLiveness(identity, table: table, home: home)
        let generic = genericPidCheck(identity)

        guard let adapterHint, adapterHint.verdict != .unknown else { return generic }
        if adapterHint.verdict == .alive, generic.verdict == .dead { return generic }
        return adapterHint
    }

    /// The harness-agnostic half: is the recorded pid running, and is it
    /// still the same process?
    public func genericPidCheck(_ identity: SessionIdentity) -> LivenessHint {
        guard let pid = identity.pid else {
            return .unknown("no pid recorded for this session")
        }
        guard let record = table.record(pid: pid) else {
            return LivenessHint(verdict: .dead, pid: pid, evidence: "pid \(pid) is not running")
        }
        guard let recorded = identity.procStart else {
            return LivenessHint(
                verdict: .alive,
                pid: pid,
                evidence: "pid \(pid) is running; no start time recorded to match against"
            )
        }
        let drift = abs(record.startTime.timeIntervalSince(recorded))
        guard drift <= tolerance else {
            return LivenessHint(
                verdict: .dead,
                pid: pid,
                evidence: "pid \(pid) was recycled: running process started "
                    + "\(Int(drift))s away from the recorded start"
            )
        }
        return LivenessHint(
            verdict: .alive,
            pid: pid,
            evidence: "pid \(pid) is running and its start time matches"
        )
    }

    /// Forgets what a session's last answer was, so the next resolution
    /// counts as a transition. A host calls this when a session is re-seeded.
    public func forget(_ key: SessionKey) {
        lastKnown[key] = nil
    }

    /// Resolves once and yields an event for every session whose liveness
    /// *changed*.
    ///
    /// Exposed separately from ``runLoop(every:identities:into:)`` so a host
    /// can drive the cadence itself — after a spawn, on a window becoming
    /// key, or from its own timer.
    @discardableResult
    public func tick(
        _ identities: [SessionIdentity],
        into continuation: AsyncStream<AgentEvent>.Continuation
    ) -> Int {
        let now = Date()
        var emitted = 0
        for identity in identities {
            let verdict = hint(for: identity).verdict
            // `unknown` is not evidence of change. Leave the last known
            // answer alone rather than making a live session flicker.
            guard verdict != .unknown else { continue }
            let alive = verdict == .alive
            guard lastKnown[identity.key] != alive else { continue }
            lastKnown[identity.key] = alive
            continuation.yield(
                AgentEvent(
                    session: identity.key,
                    timestamp: now,
                    kind: .liveness(alive: alive)
                )
            )
            emitted += 1
        }
        return emitted
    }

    /// Ticks forever, on `interval`, until the surrounding task is cancelled.
    ///
    /// `identities` is a closure rather than an array because the set of live
    /// sessions changes underneath the loop; a host passes something that
    /// reads its current snapshot table.
    ///
    /// Does not finish `continuation`: the same continuation normally also
    /// carries tailer events, and a liveness loop shutting down is not the
    /// end of the stream.
    public func runLoop(
        every interval: Duration = .seconds(3),
        identities: @escaping @Sendable () async -> [SessionIdentity],
        into continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        while !Task.isCancelled {
            tick(await identities(), into: continuation)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
