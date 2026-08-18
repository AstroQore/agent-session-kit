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
    var harness: Harness { get }

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
}
