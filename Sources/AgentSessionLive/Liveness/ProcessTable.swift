import Darwin
import Foundation
import Synchronization

/// The real process table, read through `libproc` and `sysctl`.
///
/// ## What it reads, and what it deliberately does not
///
/// The pid list and each process's BSD info (`PROC_PIDTBSDINFO`) are readable
/// for every process on the machine, so `pid`, `ppid`, `uid`, `startTime`,
/// and `name` are always populated. Everything else — the executable path,
/// the command line, the working directory — is only readable for the current
/// user's own processes, and asking about anybody else's costs a syscall to
/// be told `EPERM`. So this checks `uid` first and leaves the rest empty for
/// other users' processes, which is both faster and the honest answer: those
/// fields are unknown, not absent.
///
/// That is not a limitation in practice. Every harness this package knows
/// about runs as the person using it.
///
/// ## Caching
///
/// A liveness tick probes every session, and every probe wants the table.
/// Reading it is four hundred `proc_pidinfo` calls and, for the same-uid
/// subset, as many `sysctl` calls again — perfectly affordable once every few
/// seconds and absurd once per session per tick. So a read is cached for
/// ``maxAge``, and every query in one tick sees one consistent snapshot.
/// Snapshot semantics matter beyond performance: `children(of:)` and
/// `ancestors(of:)` walking two different tables can produce a tree that
/// never existed.
///
/// ``refresh()`` forces a new snapshot for the cases where three seconds is
/// too old — right after spawning something, most obviously.
public final class ProcessTable: ProcessTableReading {
    /// How long a snapshot is reused.
    public let maxAge: TimeInterval
    /// Whether to read command lines. Off makes a refresh roughly twice as
    /// cheap for a host that only needs liveness and never displays argv.
    public let includesArguments: Bool
    /// Whether to read working directories.
    public let includesWorkingDirectory: Bool

    private struct Snapshot {
        var records: [ProcessRecord] = []
        var byPID: [pid_t: ProcessRecord] = [:]
        var childrenByPPID: [pid_t: [ProcessRecord]] = [:]
        /// Environments read during this snapshot's window, by pid. The outer
        /// optional is "has it been asked yet", the inner one is the answer —
        /// and `nil` is worth remembering, because "another user's process,
        /// not readable" is exactly the question that gets asked repeatedly.
        var environments: [pid_t: [String: String]?] = [:]
        var takenAt: ContinuousClock.Instant?
    }

    private let snapshot: Mutex<Snapshot>
    /// How many `KERN_PROCARGS2` reads ``environment(pid:)`` has actually
    /// made. The number the environment memo exists to hold down, and the one
    /// a test can assert on instead of timing a syscall.
    private let procArgsReads = Mutex(0)

    /// Creates a table.
    ///
    /// - Parameters:
    ///   - maxAge: How long a snapshot is reused before the next query
    ///     re-reads. Three seconds is one liveness tick plus slack.
    ///   - includesArguments: Read command lines during a refresh.
    ///   - includesWorkingDirectory: Read working directories during a
    ///     refresh.
    public init(
        maxAge: TimeInterval = 3,
        includesArguments: Bool = true,
        includesWorkingDirectory: Bool = true
    ) {
        self.maxAge = maxAge
        self.includesArguments = includesArguments
        self.includesWorkingDirectory = includesWorkingDirectory
        self.snapshot = Mutex(Snapshot())
    }

    // MARK: - ProcessTableReading

    public func processes() -> [ProcessRecord] {
        current().records
    }

    public func record(pid: pid_t) -> ProcessRecord? {
        current().byPID[pid]
    }

    public func children(of pid: pid_t) -> [ProcessRecord] {
        current().childrenByPPID[pid] ?? []
    }

    public func ancestors(of pid: pid_t) -> [ProcessRecord] {
        Self.walkAncestors(from: pid, in: current().byPID)
    }

    public func find(where predicate: (ProcessRecord) -> Bool) -> [ProcessRecord] {
        current().records.filter(predicate)
    }

    /// The environment of one process, with secret-shaped values redacted.
    ///
    /// For the *current* process this reads `ProcessInfo`, not the kernel.
    /// `KERN_PROCARGS2` returns the environment as it was at `exec`, so a
    /// variable set with `setenv` after launch is invisible to it — and for
    /// our own process the live dictionary is both cheaper and correct.
    ///
    /// For anybody else's process this returns `nil` rather than an empty
    /// dictionary: "not readable" and "no environment" are different answers
    /// and only one of them means the probe learned something.
    ///
    /// Answered at most once per pid per snapshot window. Three adapters
    /// follow session ids through the environment — AntiGravity's `agy`,
    /// Cursor's worker, Claude Cowork's helper — and each of them asks about
    /// the same handful of pids once per *session*, so a board with six
    /// hundred sessions was making six hundred `KERN_PROCARGS2` calls per
    /// tick to read the same few environments. The window is the snapshot's,
    /// so the answers and the records they belong to are the same age, and
    /// ``refresh()`` clears both together.
    public func environment(pid: pid_t) -> [String: String]? {
        if pid == getpid() {
            return ArgvSanitizer.sanitizeEnvironment(ProcessInfo.processInfo.environment)
        }
        // Ensures the snapshot — and therefore the window this answer belongs
        // to — is current before anything is remembered against it.
        _ = current()
        if let remembered = snapshot.withLock({ $0.environments[pid] }) { return remembered }

        // Read outside the lock: `KERN_PROCARGS2` on a process with a large
        // environment is not something to hold every other probe behind.
        procArgsReads.withLock { $0 += 1 }
        let value = Self.readProcArgs(pid: pid).map {
            ArgvSanitizer.sanitizeEnvironment($0.environment)
        }
        snapshot.withLock { $0.environments[pid] = value }
        return value
    }

    /// How many pids' environments the current window has answers for.
    /// Diagnostics and tests.
    public func rememberedEnvironmentCount() -> Int {
        snapshot.withLock { $0.environments.count }
    }

    /// How many `KERN_PROCARGS2` reads ``environment(pid:)`` has made since
    /// this table was created. Diagnostics and tests.
    ///
    /// Counts only the environment path. The argv a snapshot carries is read
    /// during ``refresh()`` through one shared buffer, once per process, and
    /// was never the repeated cost.
    public func environmentReadCount() -> Int {
        procArgsReads.withLock { $0 }
    }

    // MARK: - Snapshot control

    /// Discards the cached snapshot and reads a new one.
    @discardableResult
    public func refresh() -> [ProcessRecord] {
        snapshot.withLock { snapshot in
            snapshot = Self.read(
                includesArguments: includesArguments,
                includesWorkingDirectory: includesWorkingDirectory
            )
            return snapshot.records
        }
    }

    /// How old the current snapshot is, or `nil` when nothing was read yet.
    public func snapshotAge() -> TimeInterval? {
        snapshot.withLock { snapshot in
            guard let takenAt = snapshot.takenAt else { return nil }
            let elapsed = ContinuousClock.now - takenAt
            return TimeInterval(elapsed.components.seconds)
                + TimeInterval(elapsed.components.attoseconds) / 1e18
        }
    }

    private func current() -> Snapshot {
        snapshot.withLock { snapshot in
            if let takenAt = snapshot.takenAt,
               ContinuousClock.now - takenAt < .seconds(maxAge) {
                return snapshot
            }
            snapshot = Self.read(
                includesArguments: includesArguments,
                includesWorkingDirectory: includesWorkingDirectory
            )
            return snapshot
        }
    }

    // MARK: - Reading

    private static func read(
        includesArguments: Bool,
        includesWorkingDirectory: Bool
    ) -> Snapshot {
        let ownUID = getuid()
        var argumentBuffer = [UInt8]()
        if includesArguments { argumentBuffer = [UInt8](repeating: 0, count: argumentsMax()) }

        var records: [ProcessRecord] = []
        var byPID: [pid_t: ProcessRecord] = [:]
        var childrenByPPID: [pid_t: [ProcessRecord]] = [:]

        for pid in allPIDs() {
            guard var info = bsdInfo(pid: pid) else { continue }
            let uid = info.pbi_uid
            let isOwn = uid == ownUID

            var argv: [String] = []
            if includesArguments, isOwn,
               let parsed = readProcArgs(pid: pid, buffer: &argumentBuffer) {
                argv = ArgvSanitizer.sanitize(parsed.argv)
            }

            let record = ProcessRecord(
                pid: pid,
                ppid: pid_t(bitPattern: info.pbi_ppid),
                uid: uid,
                startTime: startDate(&info),
                executablePath: isOwn ? executablePath(pid: pid) : "",
                name: shortName(&info),
                argv: argv,
                cwd: includesWorkingDirectory && isOwn ? workingDirectory(pid: pid) : nil
            )
            records.append(record)
            byPID[record.pid] = record
            childrenByPPID[record.ppid, default: []].append(record)
        }

        return Snapshot(
            records: records,
            byPID: byPID,
            childrenByPPID: childrenByPPID,
            takenAt: ContinuousClock.now
        )
    }

    /// Every pid the kernel will admit to. Asked for a size first, then read
    /// into a buffer with slack: processes come and go between the two calls
    /// and a buffer sized exactly right silently truncates.
    static func allPIDs() -> [pid_t] {
        let sized = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sized > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(sized) / stride + 64)
        let written = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return [] }
        let count = min(Int(written) / stride, pids.count)
        return pids.prefix(count).filter { $0 > 0 }
    }

    private static func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard read == size else { return nil }
        return info
    }

    private static func startDate(_ info: inout proc_bsdinfo) -> Date {
        let seconds = TimeInterval(info.pbi_start_tvsec)
        let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + microseconds)
    }

    private static func shortName(_ info: inout proc_bsdinfo) -> String {
        let name = cString(info.pbi_name)
        return name.isEmpty ? cString(info.pbi_comm) : name
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` from `<sys/proc_info.h>`, spelled out
    /// because it is a macro over another macro and does not survive the
    /// import into Swift.
    private static let executablePathMax = Int(MAXPATHLEN) * 4

    private static func executablePath(pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: executablePathMax)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard written > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
    }

    private static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, size)
        }
        guard read == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    // MARK: - KERN_PROCARGS2

    /// The kernel's cap on the argument block. Read once per refresh rather
    /// than hard-coded: it is a tunable.
    static func argumentsMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }

    /// Reads and splits one process's argument block.
    ///
    /// The block is `argc`, the exec path, some NUL padding, `argc`
    /// NUL-terminated arguments, and then the environment. Nothing about
    /// that layout is in a header, and it has been stable since 10.5.
    ///
    /// Fails silently — `nil` — for another user's process, for a process
    /// that exited between the pid listing and this call, and for a kernel
    /// that returned something shorter than the header. All three are normal.
    static func readProcArgs(pid: pid_t) -> (argv: [String], environment: [String: String])? {
        var buffer = [UInt8](repeating: 0, count: argumentsMax())
        return readProcArgs(pid: pid, buffer: &buffer)
    }

    static func readProcArgs(
        pid: pid_t,
        buffer: inout [UInt8]
    ) -> (argv: [String], environment: [String: String])? {
        guard !buffer.isEmpty else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(buffer, length: size)
    }

    static func parseProcArgs(
        _ buffer: [UInt8],
        length: Int
    ) -> (argv: [String], environment: [String: String])? {
        let header = MemoryLayout<Int32>.size
        guard length > header else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<header]))
            }
        }
        guard argc >= 0 else { return nil }

        var index = header
        // The exec path, then however much NUL padding the kernel used to
        // align what follows.
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }

        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        var taken = 0
        while taken < Int(argc), index < length {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
            taken += 1
        }

        var environment: [String: String] = [:]
        while index < length {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            if index > start {
                let entry = String(decoding: buffer[start..<index], as: UTF8.self)
                if let separator = entry.firstIndex(of: "=") {
                    environment[String(entry[entry.startIndex..<separator])] =
                        String(entry[entry.index(after: separator)...])
                }
            }
            index += 1
        }
        return (argv, environment)
    }

    /// Reads a fixed-size C character array — which Swift imports as a
    /// tuple — up to its first NUL.
    static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
