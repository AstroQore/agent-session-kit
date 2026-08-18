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
    /// When the process started. Pair with `pid` before trusting either.
    public let startTime: Date
    /// The executable path or name, as the process table reports it.
    public let executable: String
    /// The command line, already run through ``ArgvSanitizer/sanitize(_:)``.
    public let argv: [String]
    /// The working directory, when the platform made it available cheaply.
    public let cwd: String?

    /// Creates a record. `argv` is expected to be sanitized already.
    public init(
        pid: pid_t,
        ppid: pid_t,
        startTime: Date,
        executable: String,
        argv: [String],
        cwd: String? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.startTime = startTime
        self.executable = executable
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
}
