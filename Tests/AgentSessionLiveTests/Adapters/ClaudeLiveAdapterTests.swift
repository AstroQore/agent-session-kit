import AgentSessionKit
import Darwin
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("ClaudeLiveAdapter")
struct ClaudeLiveAdapterTests {
    private let adapter = ClaudeLiveAdapter(clock: { claudeNow })

    // MARK: - Roots

    @Test("both project roots and the sessions directory are watched")
    func watchRoots() {
        let roots = adapter.watchRoots(home: "/Users/example").map(\.path)
        #expect(roots == [
            "/Users/example/.claude/projects",
            "/Users/example/.claude/sessions",
            "/Users/example/.config/claude/projects"
        ])
    }

    @Test("the harness is Claude Code")
    func harness() {
        #expect(adapter.harness == .claudeCode)
    }

    // MARK: - Discovery

    @Test("discovery finds a transcript and its subagent, and links them")
    func discoversParentAndChild() async throws {
        let home = ClaudeHome()
        home.writeSessionEntry(pid: 4242, procStart: Date())

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        #expect(sources.count == 2)

        let parent = try #require(sources.first { $0.key == ClaudeFixture.parentKey })
        #expect(parent.primaryPath == home.transcriptPath)
        #expect(parent.auxiliaryPaths.isEmpty)
        // The `~/.claude/sessions` entry is the best source there is.
        #expect(parent.seedIdentity.cwd == ClaudeFixture.cwd)
        #expect(parent.seedIdentity.pid == 4242)
        #expect(parent.seedIdentity.procStart != nil)
        #expect(parent.seedIdentity.entrypoint == "claude-desktop")
        #expect(parent.seedIdentity.title == "demo-01")
        // The head of the file supplies what the entry does not.
        #expect(parent.seedIdentity.gitBranch == "main")
        #expect(parent.seedIdentity.parent == nil)

        let child = try #require(sources.first { $0.key == ClaudeFixture.childKey })
        #expect(child.primaryPath == home.subagentPath)
        #expect(child.seedIdentity.parent == ClaudeFixture.parentKey)
        #expect(child.seedIdentity.parentLink == .subagent(toolUseID: ClaudeFixture.toolUseID))
        #expect(child.seedIdentity.variant == ClaudeLiveAdapter.subagentVariant)
        #expect(child.seedIdentity.title == "Survey the fixture record types")
        #expect(child.seedIdentity.model == "claude-opus-5")
        // A child inherits the working directory it was spawned in.
        #expect(child.seedIdentity.cwd == ClaudeFixture.cwd)

        #expect(adapter.subagentLinker.parent(of: ClaudeFixture.childKey) == ClaudeFixture.parentKey)
    }

    @Test("a transcript with no process and no recent write is not discovered")
    func staleTranscriptsAreSkipped() async throws {
        let home = ClaudeHome()
        home.backdateTranscript(by: 7 * 24 * 3600)

        let cutoff = Date().addingTimeInterval(-3600)
        let sources = try await adapter.discover(home: home.home, activeSince: cutoff)
        #expect(sources.isEmpty)
    }

    @Test("a session with a live process is discovered however old its transcript is")
    func runningSessionsIgnoreTheCutoff() async throws {
        let home = ClaudeHome()
        home.backdateTranscript(by: 7 * 24 * 3600)
        home.writeSessionEntry(pid: 4242, procStart: Date())

        let cutoff = Date().addingTimeInterval(-3600)
        let sources = try await adapter.discover(home: home.home, activeSince: cutoff)
        // A session that has been sitting at a prompt for a week is the most
        // live thing on the machine, and its subagents come with it.
        #expect(sources.map(\.key) == [ClaudeFixture.parentKey, ClaudeFixture.childKey])
    }

    @Test("the alternate ~/.config/claude root is discovered too")
    func alternateRoot() async throws {
        let tree = TemporaryTree()
        let directory = tree.url
            .appendingPathComponent(".config/claude/projects")
            .appendingPathComponent(ClaudeFixture.projectDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: ClaudeFixture.sessionURL,
            to: directory.appendingPathComponent("\(ClaudeFixture.sessionID).jsonl")
        )

        let sources = try await adapter.discover(home: tree.path, activeSince: .distantPast)
        #expect(sources.map(\.key) == [ClaudeFixture.parentKey])
        // No `sessions` entry, so the cwd came out of the first stamped record.
        #expect(sources.first?.seedIdentity.cwd == ClaudeFixture.cwd)
    }

    @Test("a subagent with no meta file is still a session")
    func subagentWithoutMeta() async throws {
        let home = ClaudeHome()
        try FileManager.default.removeItem(
            at: home.subagentsDirectory.appendingPathComponent("agent-\(ClaudeFixture.agentID).meta.json")
        )

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let child = try #require(sources.first { $0.key == ClaudeFixture.childKey })
        #expect(child.seedIdentity.parentLink == .subagent(toolUseID: nil))
        #expect(child.seedIdentity.title == nil)
    }

    // MARK: - Liveness

    /// Our own process, which is the one process a test can be certain about.
    @discardableResult
    private func selfEntry(in home: ClaudeHome, drift: TimeInterval = 0) -> (pid_t, Date) {
        let pid = getpid()
        let started = ProcessTable().record(pid: pid)?.startTime ?? Date()
        home.writeSessionEntry(pid: pid, procStart: started.addingTimeInterval(drift))
        return (pid, started)
    }

    private func identity(_ home: ClaudeHome) -> SessionIdentity {
        SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: home.transcriptPath)
    }

    @Test("a session whose pid is running, at the recorded start time, is alive")
    func aliveWhenTheProcessMatches() {
        let home = ClaudeHome()
        let (pid, _) = selfEntry(in: home)

        let hint = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == pid)
        #expect(hint.evidence.contains("procStart"))
    }

    @Test("a subagent is exactly as alive as the session that spawned it")
    func subagentLivenessFollowsTheParent() {
        let home = ClaudeHome()
        selfEntry(in: home)

        var child = SessionIdentity(key: ClaudeFixture.childKey, sourcePath: home.subagentPath)
        child.parent = ClaudeFixture.parentKey
        let hint = adapter.probeLiveness(child, table: ProcessTable(), home: home.home)
        #expect(hint.verdict == .alive)
    }

    @Test("a pid that is running but started elsewhere is a recycled pid, not a live session")
    func recycledPidIsDead() {
        let home = ClaudeHome()
        // The entry claims the process started an hour before the one actually
        // wearing this pid did.
        selfEntry(in: home, drift: -3600)

        let hint = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("recycled"))
    }

    @Test("an entry naming a pid that is gone is dead")
    func missingProcessIsDead() {
        let home = ClaudeHome()
        home.writeSessionEntry(pid: 999_999, procStart: Date())

        let hint = adapter.probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.home
        )
        #expect(hint.verdict == .dead)
        #expect(hint.pid == 999_999)
    }

    @Test("no entry and a freshly written transcript is unknown, not dead")
    func noEntryButRecentIsUnknown() {
        let home = ClaudeHome()
        let hint = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        // A session mid-`--resume` has no entry for a moment; calling that
        // dead would flicker every row that reconnects.
        #expect(hint.verdict == .unknown)
    }

    @Test("no entry and a transcript quiet for longer than the cutoff is dead")
    func noEntryAndQuietIsDead() {
        let home = ClaudeHome()
        home.backdateTranscript(by: 3600)

        let hint = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        #expect(hint.verdict == .dead)
        #expect(hint.pid == nil)
        #expect(hint.evidence.contains("quiet"))
    }

    @Test("the messaging socket rides along as supporting evidence")
    func socketEvidence() {
        let home = ClaudeHome()
        let socket = home.tree.file("cc-sock").path
        try? Data("s".utf8).write(to: URL(fileURLWithPath: socket))
        home.writeSessionEntry(pid: getpid(), procStart: nil, socketPath: socket)

        let present = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        #expect(present.evidence.contains("messaging socket present"))

        home.writeSessionEntry(pid: getpid(), procStart: nil, socketPath: "/tmp/cc-socks/absent.sock")
        let absent = adapter.probeLiveness(identity(home), table: ProcessTable(), home: home.home)
        #expect(absent.evidence.contains("no messaging socket"))
    }

    // MARK: - Tailing

    @Test("the tailer produces what the mapper produces, with identity patches collapsed")
    func tailerMatchesTheMapper() async throws {
        let home = ClaudeHome(withSubagent: false)
        let source = SessionSource(
            key: ClaudeFixture.parentKey,
            primaryPath: home.transcriptPath,
            seedIdentity: SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: home.transcriptPath)
        )
        let tailer = try adapter.makeTailer(source, cursor: nil)
        let tailed = try await tailer.poll()

        let mapped = ClaudeFixture.sessionLines.flatMap {
            ClaudeRecordMapper.events(
                from: $0, session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
            )
        }

        // Everything but identity is passed through untouched, in order.
        func withoutIdentity(_ events: [AgentEvent]) -> [String] {
            events.map(\.kind.label).filter { $0 != "identityUpdated" }
        }
        #expect(withoutIdentity(tailed) == withoutIdentity(mapped))

        // 25 raw patches collapse to four: the opening cwd/branch/entrypoint,
        // the model the first assistant record named, the worktree move, and
        // the pinned title.
        #expect(mapped.kindCounts["identityUpdated"] == 25)
        #expect(tailed.kindCounts["identityUpdated"] == 4)

        let patches = tailed.values(identityPatch)
        #expect(patches.compactMap(\.cwd) == [ClaudeFixture.cwd, ClaudeFixture.worktree])
        #expect(patches.compactMap(\.gitBranch) == ["main", ClaudeFixture.worktreeBranch])
        #expect(patches.compactMap(\.title) == ["Claude Code live adapter"])
        #expect(patches.compactMap(\.model) == ["claude-fable-5"])

        // The tailer stamps what the mapper deliberately left alone.
        #expect(tailed.allSatisfy { $0.sequence > 0 })
        #expect(tailed.allSatisfy { $0.raw?.path == home.transcriptPath })
        #expect(try await tailer.poll().isEmpty)
    }

    @Test("a seeded tailer reads a bounded window from the end")
    func seedFromTail() async throws {
        let home = ClaudeHome(withSubagent: false)
        let source = SessionSource(
            key: ClaudeFixture.parentKey,
            primaryPath: home.transcriptPath,
            seedIdentity: SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: home.transcriptPath)
        )
        let tailer = try adapter.makeTailer(source, cursor: nil)
        let seeded = try await tailer.seedFromTail(maxBytes: 2048)

        #expect(!seeded.isEmpty)
        // The window lands well inside the file, so the head's prompt is not
        // in it but the closing title is.
        #expect(seeded.kindCounts["userPrompt"] == nil)
        #expect(seeded.values(identityPatch).compactMap(\.title) == ["Claude Code live adapter"])
        #expect(try await tailer.poll().isEmpty)
    }

    @Test("a seed identity primes the filter, so discovery's facts are not re-announced")
    func seedIdentityPrimesTheFilter() async throws {
        let home = ClaudeHome(withSubagent: false)
        home.writeSessionEntry(pid: 4242, procStart: Date())

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let tailer = try adapter.makeTailer(try #require(sources.first), cursor: nil)
        let patches = try await tailer.poll().values(identityPatch)

        // Discovery already knew the cwd, the branch, the entrypoint, and the
        // model, so only the worktree move and the title are news.
        #expect(patches.compactMap(\.cwd) == [ClaudeFixture.worktree])
        #expect(patches.compactMap(\.gitBranch) == [ClaudeFixture.worktreeBranch])
        #expect(patches.compactMap(\.entrypoint).isEmpty)
        #expect(patches.compactMap(\.title) == ["Claude Code live adapter"])
    }

    // MARK: - Subagent linking

    @Test("a subagent is announced on its parent's stream, then closed when its turn ends")
    func subagentLifecycle() async throws {
        let home = ClaudeHome()
        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let parent = try #require(sources.first { $0.key == ClaudeFixture.parentKey })
        let child = try #require(sources.first { $0.key == ClaudeFixture.childKey })

        let parentTailer = try adapter.makeTailer(parent, cursor: nil)
        let childTailer = try adapter.makeTailer(child, cursor: nil)

        // Discovery queued the start; the parent's first poll delivers it,
        // ahead of the lines it read, because the spawn came first.
        let firstParentPoll = try await parentTailer.poll()
        guard case let .subagentStarted(started, agentType, toolUseID)? = firstParentPoll.first?.kind else {
            Issue.record("the parent's first event should announce the child")
            return
        }
        #expect(started == ClaudeFixture.childKey)
        #expect(agentType == "Explore")
        #expect(toolUseID == ClaudeFixture.toolUseID)
        #expect(firstParentPoll.kindCounts["subagentFinished"] == nil)

        // The child's transcript ends its turn.
        let childEvents = try await childTailer.poll()
        #expect(childEvents.kindCounts["turnEnded"] == 1)

        let secondParentPoll = try await parentTailer.poll()
        #expect(secondParentPoll.values { kind -> SessionKey? in
            guard case let .subagentFinished(key) = kind else { return nil }
            return key
        } == [ClaudeFixture.childKey])
    }

    @Test("a child that speaks again after finishing is re-announced")
    func subagentReopens() {
        let linker = ClaudeSubagentLinker()
        linker.register(
            child: ClaudeFixture.childKey,
            parent: ClaudeFixture.parentKey,
            agentType: "Explore",
            toolUseID: ClaudeFixture.toolUseID
        )
        #expect(linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow).count == 1)

        func childEvent(_ kind: AgentEventKind) -> AgentEvent {
            AgentEvent(session: ClaudeFixture.childKey, timestamp: claudeNow, kind: kind)
        }

        linker.childProduced([childEvent(.turnEnded(reason: .complete))], child: ClaudeFixture.childKey)
        #expect(linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow).kindCounts
            == ["subagentFinished": 1])

        // Nothing in a transcript says which turn was the last one, so
        // "finished" has to be withdrawable.
        linker.childProduced([childEvent(.thinking)], child: ClaudeFixture.childKey)
        #expect(linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow).kindCounts
            == ["subagentStarted": 1])

        // And a second finish for a child already closed is not re-reported.
        linker.childProduced([childEvent(.turnEnded(reason: .complete))], child: ClaudeFixture.childKey)
        linker.childProduced([childEvent(.turnEnded(reason: .complete))], child: ClaudeFixture.childKey)
        #expect(linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow).kindCounts
            == ["subagentFinished": 1])
    }

    @Test("a parent nobody is tailing does not grow an unbounded queue")
    func linkerQueueIsBounded() {
        let linker = ClaudeSubagentLinker()
        let child = ClaudeFixture.childKey
        linker.register(child: child, parent: ClaudeFixture.parentKey, agentType: nil, toolUseID: nil)

        func childEvent(_ kind: AgentEventKind) -> AgentEvent {
            AgentEvent(session: child, timestamp: claudeNow, kind: kind)
        }
        for _ in 0..<500 {
            linker.childProduced([childEvent(.turnEnded(reason: .complete))], child: child)
            linker.childProduced([childEvent(.thinking)], child: child)
        }
        let drained = linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow)
        #expect(drained.count == ClaudeSubagentLinker.queueLimit)
    }

    @Test("registering the same child twice announces it once")
    func registrationIsIdempotent() {
        let linker = ClaudeSubagentLinker()
        for _ in 0..<5 {
            linker.register(
                child: ClaudeFixture.childKey,
                parent: ClaudeFixture.parentKey,
                agentType: "Explore",
                toolUseID: ClaudeFixture.toolUseID
            )
        }
        #expect(linker.drain(parent: ClaudeFixture.parentKey, now: claudeNow).count == 1)
    }

    // MARK: - End to end

    @Test("the fixture transcript reduces to a plausible board row")
    func reducerIntegration() async throws {
        let home = ClaudeHome(withSubagent: false)
        let source = SessionSource(
            key: ClaudeFixture.parentKey,
            primaryPath: home.transcriptPath,
            seedIdentity: SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: home.transcriptPath)
        )
        let tailer = try adapter.makeTailer(source, cursor: nil)

        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(identity: source.seedIdentity)
        for event in try await tailer.poll() {
            snapshot = reducer.reduce(snapshot, event: event)
        }

        // The transcript ends with `end_turn`, so nothing is outstanding.
        #expect(snapshot.state == .idle)
        #expect(snapshot.toolCallCount == 11)
        #expect(snapshot.turnCount == 1)
        #expect(snapshot.pending.openToolCalls.isEmpty)
        #expect(snapshot.tokensIn == 34)
        #expect(snapshot.tokensOut == 510)
        #expect(snapshot.tokensCached == 9000)
        // Identity accreted from the file rather than from discovery.
        #expect(snapshot.identity.cwd == ClaudeFixture.worktree)
        #expect(snapshot.identity.gitBranch == ClaudeFixture.worktreeBranch)
        #expect(snapshot.identity.title == "Claude Code live adapter")
        #expect(snapshot.identity.model == "claude-fable-5")
    }

    @Test("a session mid-turn reduces to something busy rather than idle")
    func reducerMidTurn() async throws {
        let home = ClaudeHome(withSubagent: false)
        // Drop the closing records so the transcript stops with a tool call
        // still open, which is what tailing a live session actually looks like.
        let lines = ClaudeFixture.sessionLines.prefix(6)
        let body = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: home.transcriptPath))

        let source = SessionSource(
            key: ClaudeFixture.parentKey,
            primaryPath: home.transcriptPath,
            seedIdentity: SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: home.transcriptPath)
        )
        let tailer = try adapter.makeTailer(source, cursor: nil)
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(identity: source.seedIdentity)
        for event in try await tailer.poll() {
            snapshot = reducer.reduce(snapshot, event: event)
        }

        #expect(snapshot.state == .toolCalling(name: "Read"))
        #expect(snapshot.toolCallCount == 2)
    }

    // MARK: - Fixture hygiene

    @Test("no fixture names a real home directory")
    func fixturesAreSynthetic() throws {
        let files = [
            ClaudeFixture.sessionURL, ClaudeFixture.subagentURL,
            ClaudeFixture.subagentMetaURL, ClaudeFixture.sessionPIDURL
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var index = text.startIndex
            while let found = text.range(of: "/Users/", range: index..<text.endIndex) {
                let rest = text[found.upperBound...]
                #expect(rest.hasPrefix("example"), "\(file.lastPathComponent) names a home that is not /Users/example")
                index = found.upperBound
            }
        }
    }
}

@Suite("ClaudeSessionsDirectory")
struct ClaudeSessionsDirectoryTests {
    @Test("an entry is parsed, and the .key beside it is not")
    func readsEntries() {
        let home = ClaudeHome()
        home.writeSessionEntry(pid: 4242, procStart: Date(timeIntervalSince1970: 1_767_603_599))

        let entries = ClaudeSessionsDirectory.read(home: home.home)
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.pid == 4242)
        #expect(entry.sessionID == ClaudeFixture.sessionID)
        #expect(entry.cwd == ClaudeFixture.cwd)
        #expect(entry.entrypoint == "claude-desktop")
        #expect(entry.kind == "interactive")
        #expect(entry.name == "demo-01")
        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_767_603_600))
        #expect(entry.procStart == Date(timeIntervalSince1970: 1_767_603_599))
    }

    @Test("procStart is UTC, not local time")
    func procStartIsUTC() {
        // `startedAt` is an unambiguous millisecond epoch written a second
        // after `procStart` by the same process, which is how the timezone was
        // established: parsing this as local time would put the two hours
        // apart on every machine that is not on UTC, and the two-second
        // recycled-pid tolerance would then call every live session dead.
        let parsed = ClaudeSessionsDirectory.procStart("Mon Jan  5 08:59:59 2026")
        #expect(parsed == Date(timeIntervalSince1970: 1_767_603_599))

        // Both `ctime(3)` day widths parse.
        #expect(ClaudeSessionsDirectory.procStart("Mon Jan 5 08:59:59 2026") == parsed)
        #expect(ClaudeSessionsDirectory.procStart("Tue Aug 18 20:38:36 2026")
            == Date(timeIntervalSince1970: 1_787_085_516))
        #expect(ClaudeSessionsDirectory.procStart(nil) == nil)
        #expect(ClaudeSessionsDirectory.procStart("not a date") == nil)
    }

    @Test("the fixture entry parses as written")
    func fixtureEntry() throws {
        let entry = try #require(ClaudeSessionsDirectory.entry(at: ClaudeFixture.sessionPIDURL))
        #expect(entry.pid == 4242)
        #expect(entry.sessionID == ClaudeFixture.sessionID)
        #expect(entry.messagingSocketPath == "/tmp/cc-socks/4242.sock")
        // The entry says the process started one second before the session did.
        #expect(entry.procStart == entry.startedAt?.addingTimeInterval(-1))
    }

    @Test("a missing directory is empty, not an error")
    func missingDirectory() {
        #expect(ClaudeSessionsDirectory.read(home: "/nonexistent/home").isEmpty)
    }

    @Test("a truncated entry is skipped rather than failing the read")
    func partialEntriesAreSkipped() {
        let home = ClaudeHome()
        home.writeSessionEntry(pid: 4242, procStart: Date())
        try? Data(#"{"pid": 99, "#.utf8).write(
            to: home.sessionsDirectory.appendingPathComponent("99.json")
        )
        try? Data(#"{"sessionId": "no-pid"}"#.utf8).write(
            to: home.sessionsDirectory.appendingPathComponent("100.json")
        )
        #expect(ClaudeSessionsDirectory.read(home: home.home).map(\.pid) == [4242])
    }

    @Test("the later process wins when two entries name one session")
    func laterProcessWins() {
        let older = ClaudeLiveSession(
            pid: 1, sessionID: "s", procStart: Date(timeIntervalSince1970: 100)
        )
        let newer = ClaudeLiveSession(
            pid: 2, sessionID: "s", procStart: Date(timeIntervalSince1970: 200)
        )
        #expect(ClaudeSessionsDirectory.session(for: "s", in: [older, newer])?.pid == 2)
        #expect(ClaudeSessionsDirectory.session(for: "other", in: [older, newer]) == nil)
    }
}

@Suite("ClaudeProjectPath")
struct ClaudeProjectPathTests {
    /// The two round-trip fixtures cannot sit under `NSTemporaryDirectory()`.
    /// A GitHub runner's temp path is
    /// `/var/folders/df/…wsm_g8s…gn/T/`, and `encode` maps that `_` to `-`
    /// like every other lossy character, so no decode can put it back — the
    /// expectation would fail for a reason that is not the decoder's, while
    /// the same path on a developer's Mac has no underscore and passes.
    /// Every component of `/private/tmp` survives the encoding.
    private func losslessTree(_ label: String = #function) -> TemporaryTree {
        TemporaryTree(label, base: "/private/tmp")
    }

    @Test("encoding replaces every character a path component cannot carry")
    func encoding() {
        #expect(ClaudeProjectPath.encode(cwd: "/Users/example/code/demo") == "-Users-example-code-demo")
        #expect(ClaudeProjectPath.encode(cwd: "/Users/example/my code/.config")
            == "-Users-example-my-code--config")
    }

    @Test("the naive decode is right for paths with no dashes in them")
    func naiveDecode() {
        #expect(ClaudeProjectPath.naiveDecode(directoryName: "-Users-example-code-demo")
            == "/Users/example/code/demo")
        #expect(ClaudeProjectPath.naiveDecode(directoryName: "") == nil)
    }

    @Test("a dash inside a component is resolved against the file system")
    func decodeChecksTheDisk() throws {
        let tree = losslessTree()
        // The ambiguity the encoding creates: `vibe-bar` and `vibe/bar` encode
        // identically, and only the disk can say which one existed.
        let real = tree.url.appendingPathComponent("code/vibe-bar")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        let encoded = ClaudeProjectPath.encode(cwd: real.path)
        #expect(ClaudeProjectPath.decode(directoryName: encoded) == real.path)
    }

    @Test("a directory that is gone falls back to the naive split for the tail")
    func decodeFallsBack() throws {
        let tree = losslessTree()
        let existing = tree.url.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let encoded = ClaudeProjectPath.encode(cwd: existing.path + "/deleted/worktree")
        let decoded = ClaudeProjectPath.decode(directoryName: encoded)
        #expect(decoded == existing.path + "/deleted/worktree")
    }

    @Test("a name that resolves to nothing still produces a guess")
    func decodeNeverResolves() {
        #expect(ClaudeProjectPath.decode(directoryName: "-nowhere-at-all") == "/nowhere/at/all")
        #expect(ClaudeProjectPath.decode(directoryName: "") == nil)
    }
}
