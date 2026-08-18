import AgentSessionKit
import Foundation

/// Live views over the stores `AgentSessionKit` reads.
///
/// `AgentSessionKit` answers "what is on disk right now": one pass, one
/// snapshot, no observers. Plenty of hosts want the other question — "tell
/// me when it changes" — and that needs a different set of trade-offs:
/// FSEvents or `DispatchSource` watches over the provider roots, debouncing
/// (a CLI rewrites a rollout many times a second while a turn streams),
/// incremental tailing that resumes from a byte offset instead of re-reading
/// a transcript, and a WAL-aware poll for the two providers whose stores are
/// SQLite databases another process keeps open.
///
/// None of that is here yet. Keeping it in a separate target from the start
/// means the parsing layer stays free of watch state, and a host that only
/// wants to list sessions never links a single file watcher.
///
/// This target is built in the Swift 6 language mode; `AgentSessionKit` is
/// still on Swift 5 while its adapters are migrated.
public enum AgentSessionLive {
    /// Marker for the not-yet-implemented live layer. Replaced by the real
    /// watcher API; present now so the target has a public symbol and
    /// downstream packages can already declare the dependency.
    public static let isImplemented = false
}
