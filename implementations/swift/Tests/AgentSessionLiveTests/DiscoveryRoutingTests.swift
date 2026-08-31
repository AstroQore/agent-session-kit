import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

// MARK: - Support

/// A ``SourceAdapter`` over one directory of JSONL files that records every
/// scope it was asked about.
///
/// The point of the recording is the whole of what routing promises: a change
/// under somebody else's root must not reach this adapter at all, and a change
/// under its own must arrive naming the directory it happened in.
struct ScopedFakeAdapter: SourceAdapter {
    let harness: Harness
    let root: URL
    /// One entry per `discover` call: the scope it was given, `nil` for a
    /// full sweep.
    let scopes: ValueBox<String?>
    /// Names this adapter refuses to treat as a session appearing.
    var ignoredSuffixes: [String] = []

    init(
        harness: Harness = .claudeCode,
        root: URL,
        scopes: ValueBox<String?> = ValueBox(),
        ignoredSuffixes: [String] = []
    ) {
        self.harness = harness
        self.root = root
        self.scopes = scopes
        self.ignoredSuffixes = ignoredSuffixes
    }

    func watchRoots(home: String) -> [URL] { [root] }

    func mightBeSessionFile(path: String) -> Bool {
        !ignoredSuffixes.contains { path.hasSuffix($0) }
    }

    func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        try await discover(home: home, activeSince: activeSince, under: nil)
    }

    func discover(
        home: String,
        activeSince: Date,
        under directory: URL?
    ) async throws -> [SessionSource] {
        await scopes.append(directory?.path)
        let searched = directory ?? root
        // Narrow honestly: only what is inside the scope.
        guard DiscoveryIO.path(searched.path, isUnder: root.path)
            || DiscoveryIO.path(root.path, isUnder: searched.path)
        else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { name in
            let path = root.appendingPathComponent(name).path
            let key = SessionKey(harness: harness, sessionID: name)
            return SessionSource(
                key: key,
                primaryPath: path,
                seedIdentity: SessionIdentity(key: key, sourcePath: path)
            )
        }
    }

    func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        JSONLTailer(source: source, cursor: cursor, decode: fixtureDecoder(key: source.key))
    }

    func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        .unknown("fixture adapter has no process to probe")
    }
}

/// The shipped defaults, minus `ignoreSelf` — which would hide the fixture
/// writes this process makes — and with the intervals a test can wait out.
private func routingConfiguration(
    rediscoverEvery: Duration = .seconds(30),
    rediscoverThrottle: Duration = .milliseconds(100),
    watcherFlags: FSEventsWatcher.CreateFlags = [.fileEvents, .noDefer, .watchRoot]
) -> IngestConfiguration {
    IngestConfiguration(
        rediscoverEvery: rediscoverEvery,
        discoveryDebounce: .milliseconds(50),
        rediscoverThrottle: rediscoverThrottle,
        watcherLatency: 0.05,
        watcherFlags: watcherFlags
    )
}

// MARK: - Routing

@Suite("Discovery routing", .serialized)
struct DiscoveryRoutingTests {
    @Test("a change reaches only the adapter whose roots contain it")
    func routedToOneAdapter() async throws {
        let tree = TemporaryTree()
        let mine = tree.url.appendingPathComponent("mine")
        let theirs = tree.url.appendingPathComponent("theirs")
        for directory in [mine, theirs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let claude = ScopedFakeAdapter(harness: .claudeCode, root: mine)
        let codex = ScopedFakeAdapter(harness: .codex, root: theirs)
        let coordinator = IngestCoordinator(
            adapters: [claude, codex],
            home: tree.path,
            configuration: routingConfiguration()
        )

        _ = await coordinator.start()
        // The opening sweep asks both, once, for everything.
        #expect(await waitUntil(timeout: .seconds(3)) { await codex.scopes.count == 1 })
        #expect(await claude.scopes.values == [nil])
        #expect(await codex.scopes.values == [nil])

        try Data(fixtureLine("hello").utf8).write(to: mine.appendingPathComponent("alpha.jsonl"))

        #expect(await waitUntil(timeout: .seconds(5)) { await claude.scopes.count >= 2 })
        // Claude Code owns that directory and was asked about it by name.
        #expect(await claude.scopes.values.dropFirst().allSatisfy { $0 == mine.path })
        // Codex owns none of it and was not woken at all.
        #expect(await codex.scopes.values == [nil])
        await coordinator.stop()
    }

    @Test("a path no adapter claims costs no discovery at all")
    func unclaimedPathIsIgnored() async throws {
        let tree = TemporaryTree()
        let adapter = ScopedFakeAdapter(root: tree.url, ignoredSuffixes: [".tmp"])
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: routingConfiguration()
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await adapter.scopes.count == 1 })

        tree.write("scratch", to: "sidecar.tmp")
        try await Task.sleep(for: .milliseconds(600))
        #expect(await adapter.scopes.count == 1)
        await coordinator.stop()
    }

    @Test("a file created under a routed directory is tailed within one poll")
    func routedFileIsTailed() async throws {
        let tree = TemporaryTree()
        let adapter = ScopedFakeAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: routingConfiguration()
        )

        let (events, _) = await coordinator.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await coordinator.trackedPaths().isEmpty)

        tree.write(fixtureLine("appeared"), to: "delta.jsonl")
        let arrived = await collectTailed(events, upTo: 1, timeout: .seconds(5))
        #expect(arrived.map(noteText) == ["appeared"])
        // The periodic sweep is thirty seconds away; routing is what found it.
        #expect(await adapter.scopes.values.contains(tree.path))
        await coordinator.stop()
    }

    @Test("the periodic sweep finds a file created while the watcher was silent")
    func sweepCoversASilentWatcher() async throws {
        let tree = TemporaryTree()
        let adapter = ScopedFakeAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            // `ignoreSelf` is the shipped default and hides this process's own
            // writes, so nothing at all is delivered for the file below. Only
            // the sweep can find it.
            configuration: routingConfiguration(
                rediscoverEvery: .milliseconds(400), watcherFlags: .default)
        )

        let (events, _) = await coordinator.start()
        try await Task.sleep(for: .milliseconds(200))
        tree.write(fixtureLine("unannounced"), to: "epsilon.jsonl")

        let arrived = await collectTailed(events, upTo: 1, timeout: .seconds(5))
        #expect(arrived.map(noteText) == ["unannounced"])
        #expect(await adapter.scopes.values.contains(nil))
        await coordinator.stop()
    }

    @Test("a burst across many directories falls back to one sweep of that store")
    func wideBurstSweeps() async throws {
        let tree = TemporaryTree()
        let adapter = ScopedFakeAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            // No watcher of its own to race with: the batch is handed over
            // directly, so the assertion is about the coordinator's rule and
            // not about how FSEvents happened to coalesce the writes.
            configuration: routingConfiguration(watcherFlags: [])
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await adapter.scopes.count == 1 })

        let paths = (0...IngestCoordinator.maximumScopes).map {
            tree.file("dir-\($0)/session.jsonl").path
        }
        await coordinator.handle(
            batch: FSEventBatch(paths: paths, flagsByPath: [:], eventIDs: [:]))

        #expect(await waitUntil(timeout: .seconds(5)) { await adapter.scopes.count >= 2 })
        // Seventeen directories is more than the coordinator tracks
        // separately, so the adapter is asked for its whole store instead.
        #expect(await adapter.scopes.values.dropFirst() == [nil])
        await coordinator.stop()
    }

    @Test("a burst inside a few directories asks about exactly those")
    func narrowBurstScopes() async throws {
        let tree = TemporaryTree()
        let adapter = ScopedFakeAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: routingConfiguration(watcherFlags: [])
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await adapter.scopes.count == 1 })

        let paths = ["one/a.jsonl", "one/b.jsonl", "two/c.jsonl"].map { tree.file($0).path }
        await coordinator.handle(
            batch: FSEventBatch(paths: paths, flagsByPath: [:], eventIDs: [:]))

        #expect(await waitUntil(timeout: .seconds(5)) { await adapter.scopes.count >= 3 })
        // Two directories, three files: one scoped pass each, not three.
        #expect(
            await adapter.scopes.values.dropFirst().compactMap { $0 }.sorted()
                == [tree.file("one").path, tree.file("two").path])
        await coordinator.stop()
    }
}

// MARK: - Scopes

@Suite("Discovery scopes")
struct DiscoveryScopeTests {
    private let home = "/Users/example"

    @Test("Grok reads a scope positionally against its sessions root")
    func grokScopes() {
        let root = GrokLiveAdapter.sessionsRoot(home: home)
        // A session directory names one session.
        let session = root.appendingPathComponent("-Users-example-work").appendingPathComponent("s1")
        let scoped = GrokLiveAdapter.scope(home: home, under: session)
        #expect(scoped.map { $0.1.path } == [session.path])
        // Something below a session directory is still that session.
        let deeper = session.appendingPathComponent("tool-results")
        #expect(GrokLiveAdapter.scope(home: home, under: deeper).map { $0.1.path } == [session.path])
        // `~/.grok`, where `active_sessions.json` lives, is the whole store —
        // and there is nothing on disk here, so the walk finds nothing.
        #expect(GrokLiveAdapter.scope(home: home, under: URL(fileURLWithPath: home + "/.grok")).isEmpty)
        // Somewhere else entirely is not this adapter's business.
        #expect(GrokLiveAdapter.scope(home: home, under: URL(fileURLWithPath: "/tmp")).isEmpty)
    }

    @Test("Codex narrows to a day directory and nothing else")
    func codexScopes() {
        let sessions = URL(fileURLWithPath: home).appendingPathComponent(CodexLiveAdapter.sessionsPath)
        let day = sessions.appendingPathComponent("2026/08/19")
        #expect(CodexLiveAdapter.dayDirectory(home: home, under: day)?.path == day.path)

        // A month, a year, the root itself, the lock directory, and a
        // directory somebody dropped in there all sweep.
        for path in ["2026/08", "2026", ""] {
            let url = path.isEmpty ? sessions : sessions.appendingPathComponent(path)
            #expect(CodexLiveAdapter.dayDirectory(home: home, under: url) == nil)
        }
        #expect(CodexLiveAdapter.dayDirectory(
            home: home,
            under: URL(fileURLWithPath: home).appendingPathComponent(CodexLiveAdapter.locksPath)
        ) == nil)
        #expect(CodexLiveAdapter.dayDirectory(
            home: home, under: sessions.appendingPathComponent("2026/08/notes")) == nil)

        // Archived rollouts are flat, so nothing under that root is a day.
        #expect(CodexLiveAdapter.dayDirectory(
            home: home,
            under: URL(fileURLWithPath: home).appendingPathComponent(CodexLiveAdapter.archivedPath)
        ) == nil)
        #expect(CodexLiveAdapter.dayDirectory(home: home, under: nil) == nil)
    }

    @Test("Claude Code narrows to a project directory, and sweeps for a pid file")
    func claudeScopes() {
        let roots = ClaudeLiveAdapter.projectRoots(home: home)
        let project = roots[0].appendingPathComponent("-Users-example-work")
        #expect(
            ClaudeLiveAdapter.projectDirectories(under: project, roots: roots)?.map(\.path)
                == [project.path])
        // A subagent's directory belongs to the same project.
        let subagents = project.appendingPathComponent("session-id/subagents")
        #expect(
            ClaudeLiveAdapter.projectDirectories(under: subagents, roots: roots)?.map(\.path)
                == [project.path])
        // `~/.claude/sessions` is under no project root: sweep.
        let sessions = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
        #expect(ClaudeLiveAdapter.projectDirectories(under: sessions, roots: roots) == nil)
    }

    @Test("Cowork reads the project directory off the path, at whatever depth")
    func coworkScopes() {
        let project = URL(
            fileURLWithPath:
                "/Users/example/Library/Application Support/Claude/local-agent-mode-sessions"
                + "/space/x/local_abc/.claude/projects/-Users-example-work")
        #expect(ClaudeCoworkLiveAdapter.projectDirectory(under: project)?.path == project.path)
        #expect(
            ClaudeCoworkLiveAdapter.projectDirectory(
                under: project.appendingPathComponent("session/subagents"))?.path == project.path)
        // Above a project directory there is nothing to narrow to.
        #expect(
            ClaudeCoworkLiveAdapter.projectDirectory(
                under: project.deletingLastPathComponent()) == nil)
    }

    @Test("AntiGravity narrows to the root a conversation store is in")
    func antigravityScopes() {
        let cli = AntigravityLiveAdapter.conversationsPath(
            home: home, root: AntigravityLiveAdapter.cliRoot)
        #expect(
            AntigravityLiveAdapter.roots(home: home, under: cli) == [AntigravityLiveAdapter.cliRoot])
        #expect(
            AntigravityLiveAdapter.roots(
                home: home,
                under: AntigravityLiveAdapter.conversationsPath(
                    home: home, root: AntigravityLiveAdapter.ideRoot)
            ) == [AntigravityLiveAdapter.ideRoot])
        // The summaries store and the presence directories carry news about
        // either root.
        #expect(
            AntigravityLiveAdapter.roots(
                home: home, under: AntigravityLiveAdapter.summariesPath(home: home)
                    .deletingLastPathComponent()
            ).count == 2)
        #expect(AntigravityLiveAdapter.roots(home: home, under: nil).count == 2)
    }

    @Test("Cursor narrows to a workspace or an agent, and sweeps elsewhere")
    func cursorScopes() {
        let adapter = CursorLiveAdapter()
        let chats = CursorPaths.chatsRoot(home: home)
        let agent = chats.appendingPathComponent("workspace-hash").appendingPathComponent("agent-1")
        #expect(adapter.agentDirectories(home: home, under: agent).map(\.path) == [agent.path])
        #expect(
            adapter.agentDirectories(home: home, under: agent.appendingPathComponent("nested"))
                .map(\.path) == [agent.path])
        // Nothing is on disk, so a scope that has to be walked finds nothing.
        #expect(adapter.agentDirectories(home: home, under: chats).isEmpty)
        #expect(adapter.agentDirectories(
            home: home, under: CursorPaths.workerRoot(home: home)).isEmpty)
    }

    @Test("containment is string arithmetic, and a prefix is not a parent")
    func containment() {
        #expect(DiscoveryIO.path("/a/b", isUnder: "/a/b"))
        #expect(DiscoveryIO.path("/a/b/c", isUnder: "/a/b"))
        #expect(DiscoveryIO.path("/a/b/c", isUnder: "/a/b/"))
        #expect(!DiscoveryIO.path("/a/bc", isUnder: "/a/b"))
        #expect(!DiscoveryIO.path("/a", isUnder: "/a/b"))
    }
}
