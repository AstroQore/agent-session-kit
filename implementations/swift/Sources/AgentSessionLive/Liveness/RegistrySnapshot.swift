import Foundation
import Synchronization

/// A fact about the whole machine, held for as long as it can still be true.
///
/// A liveness pass asks one question per session, and several of the answers
/// are not about that session at all. *Does `~/.claude/sessions` name its pid?*
/// — that is a directory listing, a JSON parse per entry, and a `ctime(3)`
/// parse per entry, and it answers for every session at once. *Does
/// `~/.grok/active_sessions.json` list its id?* — one file, one parse, same
/// thing. Asked once per session on a board with six hundred of them, three
/// seconds apart, that was the whole of the live pipeline's idle CPU once
/// discovery stopped sweeping: six hundred identical reads to learn one fact.
///
/// The answer is reused while two things hold. The file or directory it came
/// from has not moved — which is the precise test, because a session's entry
/// appearing or vanishing is a file created or removed, and that moves the
/// directory's own mtime. And it was read within ``lifetime``, which is the
/// backstop for a change a stamp cannot see, set well under the interval a
/// resolver ticks at so a verdict is never staler than the tick that carries
/// it.
///
/// Deliberately not used by discovery, which asks these questions once per
/// pass and wants the freshest answer it can get.
final class RegistrySnapshot<Value: Sendable>: Sendable {
    private struct Entry {
        let stamp: FileStamp
        let value: Value
        let at: Date
    }

    /// How long an answer is reused when the stamp has not moved.
    ///
    /// A second. The resolver ticks at three, so a tick pays for exactly one
    /// read and the answer it acts on was taken during that tick.
    static var defaultLifetime: TimeInterval { 1 }

    private let entries = Mutex<[String: Entry]>([:])
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = RegistrySnapshot.defaultLifetime) {
        self.lifetime = lifetime
    }

    /// The remembered answer for `path`, or `read()`'s.
    ///
    /// `read` runs outside the lock, so two threads racing read twice and
    /// agree — a wasted read, never a wrong answer. Holding the lock across a
    /// directory walk would serialise every session's probe behind one of them.
    func value(at path: String, now: Date = Date(), read: () -> Value) -> Value {
        let stamp = FileStamp.version(ofPath: path)
        let hit = entries.withLock { map -> Value? in
            guard let entry = map[path], entry.stamp == stamp,
                  now.timeIntervalSince(entry.at) < lifetime, now >= entry.at
            else { return nil }
            return entry.value
        }
        if let hit { return hit }

        let value = read()
        entries.withLock { map in
            map[path] = Entry(stamp: stamp, value: value, at: now)
        }
        return value
    }
}
