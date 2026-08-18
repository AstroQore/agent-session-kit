import Darwin
import Foundation

/// Two cheap questions about a file that a liveness probe can ask when the
/// harness left nothing better behind.
///
/// Several harnesses take an advisory lock on a file for as long as a session
/// is open — Codex's per-thread writer lock is the clearest case — and the
/// lock is a far better liveness signal than anything in the transcript,
/// because the kernel releases it when the process dies however the process
/// died. A transcript, by contrast, ends the same way whether the harness
/// exited cleanly or was killed.
///
/// The mtime question is the fallback for stores with no lock at all: a file
/// touched two seconds ago is being written by *something*.
public enum LockFileProbe {
    /// What `F_GETLK` found on a file.
    public enum LockState: Hashable, Sendable {
        /// Nothing holds a conflicting lock.
        case unlocked
        /// A POSIX record lock (`fcntl(F_SETLK)`) is held, by this pid.
        case held(pid: pid_t)
        /// A lock is held but the kernel will not name its owner.
        ///
        /// This is what a BSD `flock(2)` lock looks like through `F_GETLK` on
        /// Darwin: the lock is real and it does conflict, but `l_pid` comes
        /// back as `-1` because a `flock` lock belongs to an open file
        /// description rather than to a process. Rust's `File::lock` and Go's
        /// `syscall.Flock` both produce this, which covers most of the
        /// harnesses that lock anything.
        case heldByUnknownOwner
        /// The file could not be opened — usually because it does not exist.
        case unreadable

        /// `true` when something holds the lock, whoever it is.
        public var isLocked: Bool {
            switch self {
            case .held, .heldByUnknownOwner: true
            case .unlocked, .unreadable: false
            }
        }
    }

    /// The pid holding an advisory lock on `path`, when the kernel names one.
    ///
    /// Returns `nil` for an unlocked file, for a file that cannot be opened,
    /// and for a lock whose owner the kernel will not name — see
    /// ``LockState/heldByUnknownOwner``, which is the common case for
    /// `flock(2)`-based harnesses. A caller that only needs "is anyone
    /// holding this" should ask ``isLocked(path:)`` instead, or a `nil` here
    /// will read as "nobody" when it means "somebody, unnamed".
    ///
    /// One caveat that is easy to lose an afternoon to: POSIX record locks do
    /// not conflict with the process that holds them, so this always reports
    /// `unlocked` for a lock taken by the *calling* process. That is the
    /// kernel's rule, not a limitation here, and it does not matter in
    /// practice — this package never locks anything it also probes.
    public static func flockHolder(path: String) -> pid_t? {
        guard case let .held(pid) = lockState(path: path) else { return nil }
        return pid
    }

    /// `true` when anything holds a conflicting lock on `path`.
    public static func isLocked(path: String) -> Bool {
        lockState(path: path).isLocked
    }

    /// Asks the kernel what, if anything, is locking `path`.
    ///
    /// Opens read-only and asks about a whole-file write lock, which is the
    /// query that conflicts with every lock a harness might hold — read or
    /// write, whole file or first byte.
    public static func lockState(path: String) -> LockState {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        defer { close(descriptor) }

        var query = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard fcntl(descriptor, F_GETLK, &query) == 0 else { return .unreadable }
        guard query.l_type != Int16(F_UNLCK) else { return .unlocked }
        return query.l_pid > 0 ? .held(pid: query.l_pid) : .heldByUnknownOwner
    }

    /// `true` when `path` was modified within the last `seconds`.
    ///
    /// The blunt liveness signal, for stores that lock nothing and record no
    /// pid. Wrong in both directions on its own — a paused session stops
    /// writing, and a crashed one leaves a file that was fresh a moment
    /// ago — so it belongs in a hint's evidence and not in a verdict by
    /// itself.
    public static func mtimeWithin(path: String, seconds: TimeInterval) -> Bool {
        guard let stamp = FileStamp.read(path: path) else { return false }
        let age = Date().timeIntervalSince(stamp.modified)
        return age >= -1 && age <= seconds
    }

    /// How long ago `path` was modified, or `nil` when it cannot be stat'd.
    public static func ageOfLastWrite(path: String) -> TimeInterval? {
        guard let stamp = FileStamp.read(path: path) else { return nil }
        return Date().timeIntervalSince(stamp.modified)
    }
}
