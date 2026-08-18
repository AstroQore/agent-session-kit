import Foundation

/// One process, as a liveness probe needs to see it.
///
/// Named `ProcessRecord` rather than `ProcessInfo` because Foundation
/// already owns that name and a shadowing type would be a trap for every
/// caller who wrote `ProcessInfo.processInfo`.
///
/// `startTime` is not decoration. Pids are recycled, so "pid 4711 is
/// running" is not evidence that *this* session's pid 4711 is running;
/// the pair `(pid, startTime)` is what makes a process identity stable, and
/// ``SessionIdentity`` stores both for exactly this comparison.
///
/// `argv` is sanitized — see ``ArgvSanitizer``. A harness command line
/// routinely carries an API key, and this record is displayed, logged, and
/// persisted.
public struct ProcessRecord: Hashable, Codable, Sendable {
    /// The process id.
    public let pid: pid_t
    /// The parent process id, for walking a spawn tree.
    public let ppid: pid_t
    /// The real user id the process runs as.
    ///
    /// Load-bearing rather than decorative: everything interesting about a
    /// process — its command line, its environment, its working directory —
    /// is readable only for the current user's own processes, and a probe
    /// that does not check first spends a syscall per process learning
    /// `EPERM`.
    public let uid: uid_t
    /// When the process started. Pair with `pid` before trusting either.
    public let startTime: Date
    /// The absolute path to the executable, when the kernel reported one.
    /// Empty for the handful of processes it will not answer for.
    public let executablePath: String
    /// The short process name, as the kernel's own accounting records it.
    /// Truncated by the kernel, so it is a label and not an identifier.
    public let name: String
    /// The command line, already run through ``ArgvSanitizer/sanitize(_:)``.
    /// Empty for another user's process, which is not the same as a process
    /// that was launched with no arguments.
    public let argv: [String]
    /// The working directory, when the platform made it available cheaply.
    public let cwd: String?

    /// Creates a record. `argv` is expected to be sanitized already.
    ///
    /// `name` defaults to the last component of `executablePath`, which is
    /// what a fixture almost always wants; the real table passes the
    /// kernel's own short name instead.
    public init(
        pid: pid_t,
        ppid: pid_t,
        uid: uid_t = getuid(),
        startTime: Date,
        executablePath: String,
        name: String? = nil,
        argv: [String],
        cwd: String? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.startTime = startTime
        self.executablePath = executablePath
        self.name = name ?? (executablePath as NSString).lastPathComponent
        self.argv = argv
        self.cwd = cwd
    }
}

/// A readable process table.
///
/// An abstraction with exactly one purpose: making liveness testable.
/// A real implementation reads `sysctl(KERN_PROC_ALL)`; the suite hands
/// adapters a fixed array and drives every branch — matched pid, recycled
/// pid, missing process, orphaned child — without depending on what is
/// running on the machine.
///
/// Both calls must be cheap and non-throwing. A probe runs per session per
/// tick, and a table read that can fail would turn a transient `sysctl`
/// hiccup into a board full of dead sessions. Failure is expressed as an
/// empty array or a `nil` environment, and a probe reads either as
/// ``LivenessHint/Verdict/unknown`` rather than as death.
public protocol ProcessTableReading: Sendable {
    /// Every process currently visible to this user, with sanitized argv.
    func processes() -> [ProcessRecord]

    /// The environment of one process, with secret-shaped values redacted,
    /// or `nil` when it cannot be read.
    ///
    /// Used to follow session ids that harnesses pass to their children
    /// through the environment. Implementations must run the dictionary
    /// through ``ArgvSanitizer/sanitizeEnvironment(_:)`` before returning it:
    /// a process environment is where the API keys actually live.
    func environment(pid: pid_t) -> [String: String]?

    /// One process by id, or `nil` when it is not in the table.
    func record(pid: pid_t) -> ProcessRecord?

    /// The direct children of `pid`, in no particular order.
    func children(of pid: pid_t) -> [ProcessRecord]

    /// The chain from `pid`'s parent up to the root, nearest first.
    ///
    /// A harness that shelled out to another harness is only visible this
    /// way: neither log records the other, and the spawn tree is the whole
    /// of the evidence behind ``ParentLink/spawnedProcess``.
    func ancestors(of pid: pid_t) -> [ProcessRecord]

    /// Every process matching `predicate`.
    func find(where predicate: (ProcessRecord) -> Bool) -> [ProcessRecord]
}

/// Default implementations over ``ProcessTableReading/processes()``.
///
/// Correct for any conformer, and adequate for the fixed arrays the suite
/// uses. ``ProcessTable`` overrides all four, because a linear scan per
/// query over four hundred processes is the difference between a probe that
/// costs nothing and one a person notices.
extension ProcessTableReading {
    public func record(pid: pid_t) -> ProcessRecord? {
        processes().first { $0.pid == pid }
    }

    public func children(of pid: pid_t) -> [ProcessRecord] {
        processes().filter { $0.ppid == pid }
    }

    public func ancestors(of pid: pid_t) -> [ProcessRecord] {
        let table = processes()
        var byPID: [pid_t: ProcessRecord] = [:]
        for record in table { byPID[record.pid] = record }
        return Self.walkAncestors(from: pid, in: byPID)
    }

    public func find(where predicate: (ProcessRecord) -> Bool) -> [ProcessRecord] {
        processes().filter(predicate)
    }

    /// Walks parent links, stopping at the root, at a missing parent, or at
    /// a cycle. The cycle guard is not paranoia: the table is a snapshot
    /// assembled from many `proc_pidinfo` calls, and pid reuse between the
    /// first call and the last can genuinely produce one.
    static func walkAncestors(from pid: pid_t, in byPID: [pid_t: ProcessRecord]) -> [ProcessRecord] {
        var chain: [ProcessRecord] = []
        var seen: Set<pid_t> = [pid]
        var current = byPID[pid]?.ppid ?? 0
        while current > 0, seen.insert(current).inserted, let record = byPID[current] {
            chain.append(record)
            current = record.ppid
        }
        return chain
    }
}
