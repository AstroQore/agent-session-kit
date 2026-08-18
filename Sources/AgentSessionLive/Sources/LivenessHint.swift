import Foundation

/// What a process probe concluded about a session, and why.
///
/// A hint is not a verdict a UI shows. It is one adapter's reading of the
/// process table, which a resolver combines with what the transcript said
/// before emitting ``AgentEventKind/liveness(alive:)``. Adapters disagree
/// legitimately — a Cursor session has no process of its own while the app
/// is running, and a `codex exec` under a Claude Code turn has one that
/// belongs to neither cleanly — so ``Verdict/unknown`` is a real answer and
/// not a failure.
///
/// `evidence` is for a person debugging a wrong row: "matched pid 4711
/// started 12s before the first transcript line". It is a display string and
/// must already be sanitized — no full paths, no argv values that were not
/// run through ``ArgvSanitizer``.
public struct LivenessHint: Hashable, Codable, Sendable {
    /// A probe's conclusion.
    public enum Verdict: String, Codable, Sendable, CaseIterable, Hashable {
        /// A process was matched and is running.
        case alive
        /// The process that owned this session is provably gone.
        case dead
        /// The probe cannot tell. Not an error: several stores genuinely
        /// carry no way to identify their own process.
        case unknown
    }

    /// What the probe concluded.
    public let verdict: Verdict
    /// The process the verdict is about, when one was matched.
    public let pid: pid_t?
    /// Sanitized, human-readable reasoning behind the verdict.
    public let evidence: String

    /// Creates a hint.
    public init(verdict: Verdict, pid: pid_t? = nil, evidence: String) {
        self.verdict = verdict
        self.pid = pid
        self.evidence = evidence
    }

    /// A hint that says nothing, for adapters with no way to probe.
    public static func unknown(_ evidence: String) -> LivenessHint {
        LivenessHint(verdict: .unknown, pid: nil, evidence: evidence)
    }
}
