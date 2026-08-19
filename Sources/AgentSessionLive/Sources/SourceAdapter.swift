import AgentSessionKit
import Foundation

/// Everything the live layer needs to know about one harness's store.
///
/// The live counterpart of `AgentSessionKit`'s `SessionProviderAdapter`, and
/// deliberately a separate protocol: that one answers "what is on disk right
/// now" in a single pass, this one answers "tell me when it changes", and the
/// two have different failure modes, different costs, and different lifetimes.
///
/// Every entry point takes an explicit `home`. Nothing in this package
/// invents a location under `~/`, and an adapter that did would be
/// untestable — the suite runs against synthetic trees in a temporary
/// directory and never touches a real home.
public protocol SourceAdapter: Sendable {
    /// The harness this adapter reads.
    ///
    /// One adapter has one primary harness, and it is what a notice or a log
    /// line names when something goes wrong inside it. When a single store
    /// carries more than one harness's sessions, list the rest in
    /// ``handledHarnesses``.
    var harness: Harness { get }

    /// Every harness whose sessions this adapter can key and probe.
    ///
    /// Almost always just ``harness``, and the default implementation says
    /// so. The exception is a store shared by two harnesses:
    /// `~/.codex/sessions` holds both Codex and ChatGPT Work rollouts, told
    /// apart only by the header's `originator`, and one adapter reads both.
    ///
    /// A host that indexes adapters by harness — ``LivenessResolver`` does,
    /// because a probe is per-harness by construction — must index by this
    /// rather than by ``harness``, or the second harness's sessions get no
    /// probe at all and every one of them shows up as liveness `unknown`.
    var handledHarnesses: [Harness] { get }

    /// The directories a file-system watcher should subscribe to.
    ///
    /// As narrow as the store actually is: this is the scope of every watch
    /// the host will install, and a root that is wider than the store means
    /// waking on changes that can never be relevant. Directories that do not
    /// exist are returned anyway — a harness installed later must be picked
    /// up without a restart.
    func watchRoots(home: String) -> [URL]

    /// Finds the sources worth tailing, ignoring anything untouched since
    /// `activeSince`.
    ///
    /// The cutoff is what keeps discovery bounded on a machine with years of
    /// transcripts: a board shows what is happening now, and a session that
    /// has not been written to in a week is not it.
    func discover(home: String, activeSince: Date) async throws -> [SessionSource]

    /// The same, narrowed to the part of the store that just changed.
    ///
    /// A file-system notification names a path. A host that answers it by
    /// asking every adapter to sweep its whole store pays for the whole
    /// machine's history every time a live transcript gains a line, which on
    /// a machine with hundreds of sessions is most of the CPU a board burns
    /// while nothing is happening. So the host asks the one adapter whose
    /// roots contain the path, about the one directory the path is in.
    ///
    /// `directory` is a directory at or below one of ``watchRoots(home:)``,
    /// or `nil` for "the whole store" — which is what the periodic safety
    /// net asks for. An implementation must return every source
    /// ``discover(home:activeSince:)`` would have returned whose primary
    /// path lies at or below `directory`. Returning *more* than that is
    /// always safe: the host registers only sources it does not already
    /// have. An adapter that cannot narrow a particular directory should
    /// sweep rather than return nothing.
    ///
    /// The default sweeps, so an adapter that has not thought about it stays
    /// correct and merely as expensive as it always was. Narrowing is worth
    /// implementing for a store big enough that a sweep is felt.
    func discover(home: String, activeSince: Date, under directory: URL?) async throws -> [SessionSource]

    /// Builds a tailer for a source, resuming from `cursor` when one was
    /// persisted.
    ///
    /// Passing `nil` means cold start, and the returned tailer is expected to
    /// be seeded with ``SessionTailer/seedFromTail(maxBytes:)`` rather than
    /// read from the beginning. A cursor that no longer fits the source — an
    /// inode that changed, a row id past the end — is discarded by the
    /// tailer, not by the caller.
    func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer

    /// Decides whether the harness process behind `identity` is still
    /// running.
    ///
    /// Synchronous and pure with respect to `table`: the process table is
    /// injected so that the suite can drive every branch off a fixed list of
    /// processes instead of whatever happens to be running. Returning
    /// ``LivenessHint/Verdict/unknown`` is correct and expected for stores
    /// with no process of their own.
    func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint

    /// Whether a change at `path` — one nothing currently tails — could be
    /// a session this adapter would discover, as opposed to a sidecar the
    /// harness writes next to its sessions.
    ///
    /// The host asks before running a full rediscovery on an unknown path.
    /// A store writes many things that are not sessions — Grok rewrites
    /// `summary.json` every turn, Claude Code spills tool output into
    /// `tool-results/`, AntiGravity touches a presence lock — and treating
    /// each as "a session appeared" turns discovery into a hot loop. Cheap
    /// and syntactic: look at the name, never at the contents. Default is
    /// `true`, so an adapter that has not thought about it stays correct
    /// and merely wakes the host more than it needs to.
    func mightBeSessionFile(path: String) -> Bool
}

public extension SourceAdapter {
    var handledHarnesses: [Harness] { [harness] }

    func mightBeSessionFile(path: String) -> Bool { true }

    func discover(home: String, activeSince: Date, under directory: URL?) async throws -> [SessionSource] {
        try await discover(home: home, activeSince: activeSince)
    }
}
