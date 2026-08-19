import AgentSessionKit
import Darwin
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("ProcessTable")
struct ProcessTableTests {
    @Test("the table contains this process, correctly described")
    func containsSelf() throws {
        let table = ProcessTable()
        let me = try #require(table.record(pid: getpid()))

        #expect(me.pid == getpid())
        #expect(me.ppid == getppid())
        #expect(me.uid == getuid())
        #expect(!me.executablePath.isEmpty)
        #expect(!me.name.isEmpty)
        // Own process, so argv is readable and starts with the executable.
        #expect(!me.argv.isEmpty)
        // Started in the past, and not in 1970.
        #expect(me.startTime < Date())
        #expect(me.startTime > Date(timeIntervalSince1970: 1_000_000_000))
    }

    @Test("another user's process is listed but not described")
    func otherUsersAreOpaque() {
        let table = ProcessTable()
        // pid 1 is `launchd`, which runs as root on every Mac.
        guard let launchd = table.record(pid: 1), launchd.uid != getuid() else { return }
        #expect(launchd.argv.isEmpty)
        #expect(launchd.executablePath.isEmpty)
        // The facts that come from PROC_PIDTBSDINFO are readable regardless.
        #expect(!launchd.name.isEmpty)
    }

    @Test("a spawned child shows up under this process")
    func childIsVisible() async throws {
        let table = ProcessTable(maxAge: 0)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let found = await waitUntil(timeout: .seconds(3)) {
            table.refresh()
            return table.children(of: getpid()).contains { $0.pid == child.processIdentifier }
        }
        #expect(found, "spawned /bin/sleep did not appear under pid \(getpid())")

        let record = try #require(table.record(pid: child.processIdentifier))
        #expect(record.ppid == getpid())
        #expect(record.name.contains("sleep"))
        #expect(record.argv.first?.contains("sleep") == true)
        #expect(table.ancestors(of: child.processIdentifier).contains { $0.pid == getpid() })
    }

    @Test("the environment of this process is redacted, not leaked")
    func environmentIsRedacted() throws {
        setenv("AUSPEX_TEST_TOKEN", "hunter2", 1)
        setenv("AUSPEX_TEST_PLAIN", "not-a-secret", 1)
        defer {
            unsetenv("AUSPEX_TEST_TOKEN")
            unsetenv("AUSPEX_TEST_PLAIN")
        }

        let table = ProcessTable()
        let environment = try #require(table.environment(pid: getpid()))

        // `setenv` changes the live environment, which `KERN_PROCARGS2` never
        // sees — it reports the block as it was at `exec`. Reading `ProcessInfo`
        // for our own pid is what makes this both correct and observable.
        #expect(environment["AUSPEX_TEST_TOKEN"] == ArgvSanitizer.redactionPlaceholder)
        #expect(environment["AUSPEX_TEST_PLAIN"] == "not-a-secret")
        #expect(!environment.values.contains("hunter2"))
    }

    @Test("a pid that is not running has no environment")
    func missingProcessEnvironment() {
        let table = ProcessTable()
        // Above the default `kern.maxproc`, so it cannot be a live pid.
        #expect(table.environment(pid: 999_999) == nil)
    }

    @Test("a pid's environment is read once per window, and survives the process")
    func environmentIsReadOncePerWindow() async throws {
        let table = ProcessTable(maxAge: 60, includesArguments: false, includesWorkingDirectory: false)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        // What is asserted is that the question is *answered*, not what the
        // answer says: `KERN_PROCARGS2` hands over argv for a system binary
        // but strips its environment, so `/bin/sleep` reports an empty
        // dictionary rather than a populated one. Empty and unreadable are
        // still different answers, and only the first is non-`nil`.
        #expect(await waitUntil(timeout: .seconds(3)) {
            table.refresh()
            return table.environment(pid: pid) != nil
        })
        #expect(table.rememberedEnvironmentCount() == 1)

        // Six hundred sessions asking about the same pid is the case this
        // exists for: it is one process, not six hundred.
        for _ in 0..<600 {
            #expect(table.environment(pid: pid) != nil)
        }
        #expect(table.rememberedEnvironmentCount() == 1)

        // The answer outliving the process is what proves it was remembered:
        // the kernel has nothing left to tell about a reaped pid.
        child.terminate()
        child.waitUntilExit()
        #expect(table.environment(pid: pid) != nil)

        // And a new window asks again, and gets the truth.
        table.refresh()
        #expect(table.rememberedEnvironmentCount() == 0)
        #expect(table.environment(pid: pid) == nil)
    }

    @Test("a table that caches nothing still answers, without taking a snapshot")
    func zeroWindowDoesNotCacheOrRefresh() {
        // `maxAge: 0` means every answer fresh. Nothing is remembered, and
        // asking about an environment must not force a whole table read to
        // discover that.
        let table = ProcessTable(maxAge: 0, includesArguments: false, includesWorkingDirectory: false)
        #expect(table.snapshotAge() == nil)
        #expect(table.environment(pid: 999_999) == nil)
        #expect(table.rememberedEnvironmentCount() == 0)
        #expect(table.snapshotAge() == nil)
    }

    @Test("an unreadable environment is remembered too")
    func unreadableEnvironmentIsRemembered() {
        let table = ProcessTable(maxAge: 60, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        // Above the default `kern.maxproc`, so it cannot be a live pid — and
        // "not readable" is the answer the probes ask for most often, so it is
        // the one worth not asking twice.
        for _ in 0..<50 {
            #expect(table.environment(pid: 999_999) == nil)
        }
        #expect(table.rememberedEnvironmentCount() == 1)
    }

    @Test("this process's environment is never cached, because it is live")
    func ownEnvironmentIsNotCached() {
        let table = ProcessTable(maxAge: 60, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        setenv("AUSPEX_TEST_LIVE", "first", 1)
        defer { unsetenv("AUSPEX_TEST_LIVE") }
        #expect(table.environment(pid: getpid())?["AUSPEX_TEST_LIVE"] == "first")

        // `ProcessInfo` is the live dictionary, so a later `setenv` shows up —
        // caching it would make our own environment the one thing in here that
        // goes stale.
        setenv("AUSPEX_TEST_LIVE", "second", 1)
        #expect(table.environment(pid: getpid())?["AUSPEX_TEST_LIVE"] == "second")
        #expect(table.rememberedEnvironmentCount() == 0)
    }

    @Test("the snapshot is reused inside its window and replaced after it")
    func cachingWindow() async throws {
        let table = ProcessTable(maxAge: 60, includesArguments: false, includesWorkingDirectory: false)
        _ = table.processes()
        let firstAge = try #require(table.snapshotAge())
        try await Task.sleep(for: .milliseconds(100))
        _ = table.processes()
        let secondAge = try #require(table.snapshotAge())
        // No re-read, so the snapshot only got older.
        #expect(secondAge > firstAge)

        table.refresh()
        #expect(try #require(table.snapshotAge()) < firstAge + 0.5)
    }

    @Test("the argument block splits into argv and environment")
    func procArgsParsing() throws {
        // Hand-built in the layout `KERN_PROCARGS2` returns: argc, the exec
        // path, NUL padding, argc arguments, then the environment.
        var bytes: [UInt8] = []
        var argc: Int32 = 2
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array("/usr/local/bin/harness".utf8))
        bytes.append(contentsOf: [0, 0, 0])
        bytes.append(contentsOf: Array("harness".utf8) + [0])
        bytes.append(contentsOf: Array("--resume".utf8) + [0])
        bytes.append(contentsOf: Array("HOME=/Users/example".utf8) + [0])
        bytes.append(contentsOf: Array("ANTHROPIC_API_KEY=sk-secret-value".utf8) + [0])

        let parsed = try #require(ProcessTable.parseProcArgs(bytes, length: bytes.count))
        #expect(parsed.argv == ["harness", "--resume"])
        #expect(parsed.environment["HOME"] == "/Users/example")
        #expect(parsed.environment["ANTHROPIC_API_KEY"] == "sk-secret-value")

        // Which is exactly why nothing hands the raw block to a caller.
        let sanitised = ArgvSanitizer.sanitizeEnvironment(parsed.environment)
        #expect(sanitised["ANTHROPIC_API_KEY"] == ArgvSanitizer.redactionPlaceholder)
        #expect(sanitised["HOME"] == "/Users/example")
    }

    @Test("a truncated argument block is rejected rather than misread")
    func procArgsTruncated() {
        #expect(ProcessTable.parseProcArgs([1, 2], length: 2) == nil)
        #expect(ProcessTable.parseProcArgs([], length: 0) == nil)
    }

    @Test("listing pids returns something plausible")
    func pidListing() {
        let pids = ProcessTable.allPIDs()
        #expect(pids.count > 10)
        #expect(pids.contains(getpid()))
        #expect(pids.allSatisfy { $0 > 0 })
    }

    @Test("ancestor walking stops at a cycle instead of spinning")
    func ancestorCycle() {
        let a = ProcessRecord(pid: 10, ppid: 11, startTime: epoch, executablePath: "/a", argv: [])
        let b = ProcessRecord(pid: 11, ppid: 10, startTime: epoch, executablePath: "/b", argv: [])
        let table = FakeProcessTable(records: [a, b])
        let chain = table.ancestors(of: 10)
        #expect(chain.map(\.pid) == [11])
    }

    @Test("the protocol's default queries work over a fixed table")
    func defaultQueries() {
        let parent = ProcessRecord(pid: 100, ppid: 1, startTime: epoch, executablePath: "/bin/parent", argv: [])
        let child = ProcessRecord(pid: 101, ppid: 100, startTime: epoch, executablePath: "/bin/child", argv: [])
        let stranger = ProcessRecord(pid: 200, ppid: 1, startTime: epoch, executablePath: "/bin/other", argv: [])
        let table = FakeProcessTable(records: [parent, child, stranger])

        #expect(table.record(pid: 101)?.name == "child")
        #expect(table.children(of: 100).map(\.pid) == [101])
        #expect(table.ancestors(of: 101).map(\.pid) == [100])
        #expect(table.find { $0.ppid == 1 }.map(\.pid) == [100, 200])
        #expect(table.record(pid: 999) == nil)
    }
}
