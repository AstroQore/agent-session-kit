import AgentSessionKit
import Darwin
import Foundation
import Testing
@testable import AgentSessionLive

// MARK: - A synthetic Cowork home

/// The tree Claude.app writes for a local agent run, built from the same flat
/// fixtures the Claude Code adapter tests use.
///
/// The workspace segments between the root and `.claude` (`<space>/<x>/
/// `local_<uuid>`) are Claude.app's own bookkeeping and are deliberately
/// arbitrary here: the adapter must find the transcripts without knowing how
/// deep they are, because that depth is not something this package should
/// encode.
private struct CoworkHome {
    let tree: TemporaryTree

    /// The tree's path with every symlink resolved.
    ///
    /// `FileManager.enumerator` hands back resolved paths — a temporary tree
    /// under `/var` comes back as `/private/var` — and the adapter reports
    /// what the sweep found. `ClaudeCoworkPaths` documents the same thing,
    /// which is why it recognises a Cowork transcript by path *component*
    /// rather than by a prefix match against the root. Resolving the home
    /// once here compares like with like instead of papering over it.
    var home: String { Self.real(tree.path) }

    /// `realpath(3)`, because `URL.resolvingSymlinksInPath()` deliberately
    /// strips a leading `/private` and would hand back the path we started
    /// with.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    var workspace: URL {
        ClaudeCoworkPaths.root(homeDirectory: home)
            .appendingPathComponent("space-01/a/local_7f2c9b18-0000-4000-8000-abcdefabcdef")
    }

    var projectDirectory: URL {
        workspace
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(ClaudeFixture.projectDirectory)
    }

    var transcriptPath: String {
        projectDirectory.appendingPathComponent("\(ClaudeFixture.sessionID).jsonl").path
    }

    var subagentsDirectory: URL {
        projectDirectory
            .appendingPathComponent(ClaudeFixture.sessionID)
            .appendingPathComponent("subagents")
    }

    var subagentPath: String {
        subagentsDirectory.appendingPathComponent("agent-\(ClaudeFixture.agentID).jsonl").path
    }

    init(_ label: String = #function, withSubagent: Bool = true) {
        tree = TemporaryTree(label)
        let manager = FileManager.default
        try? manager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try? manager.copyItem(at: ClaudeFixture.sessionURL, to: URL(fileURLWithPath: transcriptPath))
        Self.touch(transcriptPath)
        guard withSubagent else { return }
        try? manager.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        try? manager.copyItem(at: ClaudeFixture.subagentURL, to: URL(fileURLWithPath: subagentPath))
        Self.touch(subagentPath)
        try? manager.copyItem(
            at: ClaudeFixture.subagentMetaURL,
            to: subagentsDirectory.appendingPathComponent("agent-\(ClaudeFixture.agentID).meta.json")
        )
    }

    /// `copyItem` preserves the fixture's modification date, which is whenever
    /// the checkout happened. Stamp the copies with now so the tests describe
    /// the file rather than the clone.
    private static func touch(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    /// Ages the transcript so the quiet branches can be driven without waiting.
    func backdateTranscript(by seconds: TimeInterval) {
        let when = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes(
            [.modificationDate: when], ofItemAtPath: transcriptPath)
    }

    /// Writes a file the sweep must ignore: the right extension, inside the
    /// workspace, but not under a `.claude/projects` directory.
    @discardableResult
    func writeStrayJSONL() -> URL {
        let url = workspace.appendingPathComponent(".claude/history/notes.jsonl")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}\n".utf8).write(to: url)
        return url
    }
}

private let coworkKey = SessionKey(harness: .claudeCowork, sessionID: ClaudeFixture.sessionID)
private let coworkChildKey = SessionKey(
    harness: .claudeCowork,
    sessionID: "\(ClaudeFixture.sessionID)/agent-\(ClaudeFixture.agentID)")

/// A Claude.app helper process, as the process table would report it.
private func helper(pid: pid_t) -> ProcessRecord {
    ProcessRecord(
        pid: pid,
        ppid: 1,
        startTime: Date(),
        executablePath: "/Applications/Claude.app/Contents/Frameworks/claude-code/bin/claude",
        argv: ["claude"]
    )
}

// MARK: - Tests

@Suite("ClaudeCoworkLiveAdapter")
struct ClaudeCoworkLiveAdapterTests {
    private let adapter = ClaudeCoworkLiveAdapter(clock: { claudeNow })

    // MARK: - Identity and roots

    @Test("the harness is Claude Cowork, and only that")
    func harness() {
        #expect(adapter.harness == .claudeCowork)
        #expect(adapter.handledHarnesses == [.claudeCowork])
    }

    @Test("the one watch root is Claude.app's local-agent-mode tree")
    func watchRoots() {
        #expect(adapter.watchRoots(home: "/Users/example").map(\.path) == [
            "/Users/example/Library/Application Support/Claude/local-agent-mode-sessions"
        ])
    }

    // MARK: - Discovery

    @Test("discovery finds a nested transcript and its subagent, keyed to Cowork")
    func discoversParentAndChild() async throws {
        let home = CoworkHome()
        home.writeStrayJSONL()

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        #expect(sources.count == 2)

        let parent = try #require(sources.first { $0.key == coworkKey })
        #expect(parent.primaryPath == home.transcriptPath)
        // No `~/.claude/sessions` entry exists for a Cowork run, so everything
        // knowable comes from the head of the transcript.
        #expect(parent.seedIdentity.pid == nil)
        #expect(parent.seedIdentity.cwd == ClaudeFixture.cwd)
        #expect(parent.seedIdentity.gitBranch == "main")

        let child = try #require(sources.first { $0.key == coworkChildKey })
        #expect(child.primaryPath == home.subagentPath)
        #expect(child.seedIdentity.parent == coworkKey)
        #expect(child.seedIdentity.parentLink == .subagent(toolUseID: ClaudeFixture.toolUseID))
        #expect(child.seedIdentity.variant == ClaudeLiveAdapter.subagentVariant)
    }

    @Test("a transcript older than the window is skipped")
    func discoveryWindow() async throws {
        let home = CoworkHome(withSubagent: false)
        home.backdateTranscript(by: 7 * 86_400)

        let recent = try await adapter.discover(
            home: home.home, activeSince: Date().addingTimeInterval(-3600))
        #expect(recent.isEmpty)

        let everything = try await adapter.discover(home: home.home, activeSince: .distantPast)
        #expect(everything.map(\.key) == [coworkKey])
    }

    @Test("an empty home discovers nothing and does not throw")
    func emptyHome() async throws {
        let tree = TemporaryTree()
        #expect(try await adapter.discover(home: tree.path, activeSince: .distantPast).isEmpty)
    }

    @Test("the events a tailer produces carry the Cowork key")
    func tailedEventsKeepTheHarness() async throws {
        let home = CoworkHome(withSubagent: false)
        let source = try #require(
            try await adapter.discover(home: home.home, activeSince: .distantPast).first)
        let events = try await adapter.makeTailer(source, cursor: nil)
            .seedFromTail(maxBytes: 1 << 20)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.session == coworkKey })
    }

    // MARK: - What could be a session

    @Test("only .jsonl below a .claude/projects directory could be a session")
    func mightBeSessionFile() {
        let root = "/Users/example/Library/Application Support/Claude/local-agent-mode-sessions"
        #expect(adapter.mightBeSessionFile(path: "\(root)/s/a/local_1/.claude/projects/p/x.jsonl"))
        #expect(adapter.mightBeSessionFile(
            path: "\(root)/s/a/local_1/.claude/projects/p/x/subagents/agent-1.jsonl"))
        #expect(!adapter.mightBeSessionFile(path: "\(root)/s/a/local_1/.claude/settings.json"))
        #expect(!adapter.mightBeSessionFile(
            path: "\(root)/s/a/local_1/.claude/projects/p/x/tool-results/1.txt"))
        #expect(!adapter.mightBeSessionFile(path: "\(root)/s/a/local_1/.claude/history/notes.jsonl"))
    }

    // MARK: - Liveness

    private func identity(_ home: CoworkHome, key: SessionKey = coworkKey) -> SessionIdentity {
        SessionIdentity(key: key, sourcePath: home.transcriptPath)
    }

    @Test("a Claude.app helper carrying the session id is the session's process")
    func helperProcessNamesTheSession() {
        let home = CoworkHome(withSubagent: false)
        let table = FakeProcessTable(
            records: [helper(pid: 4242)],
            environments: [4242: [
                SessionEnvironmentVariables.claudeSessionID: ClaudeFixture.sessionID,
                "PATH": "/usr/bin"
            ]])

        let hint = adapter.probeLiveness(identity(home), table: table, home: home.home)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4242)
        #expect(hint.evidence.contains("4242"))
    }

    @Test("a subagent is as alive as the session it was spawned from")
    func subagentFollowsItsParent() {
        let home = CoworkHome()
        let table = FakeProcessTable(
            records: [helper(pid: 4242)],
            environments: [4242: [
                SessionEnvironmentVariables.claudeSessionID: ClaudeFixture.sessionID
            ]])

        let hint = adapter.probeLiveness(
            identity(home, key: coworkChildKey), table: table, home: home.home)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4242)
    }

    @Test("a process outside Claude.app is not a Cowork helper, whatever its environment")
    func foreignProcessIsIgnored() {
        let home = CoworkHome(withSubagent: false)
        // A terminal that exported the variable by hand. It proves nothing,
        // so the answer falls back to the transcript's own freshness.
        let table = FakeProcessTable(
            records: [ProcessRecord(
                pid: 5150, ppid: 1, startTime: Date(),
                executablePath: "/opt/homebrew/bin/claude", argv: ["claude"])],
            environments: [5150: [
                SessionEnvironmentVariables.claudeSessionID: ClaudeFixture.sessionID
            ]])

        let hint = adapter.probeLiveness(identity(home), table: table, home: home.home)
        #expect(hint.pid == nil)
        #expect(hint.evidence.contains("no Claude.app helper"))
    }

    @Test("a helper naming a different session does not vouch for this one")
    func helperForAnotherSession() {
        let home = CoworkHome(withSubagent: false)
        home.backdateTranscript(by: 20 * 60)
        let table = FakeProcessTable(
            records: [helper(pid: 4242)],
            environments: [4242: [
                SessionEnvironmentVariables.claudeSessionID: "some-other-session"
            ]])

        #expect(adapter.probeLiveness(identity(home), table: table, home: home.home).verdict == .dead)
    }

    @Test("with no helper, a freshly written transcript is alive")
    func freshTranscriptIsAlive() {
        let home = CoworkHome(withSubagent: false)
        let hint = adapter.probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.home)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == nil)
    }

    @Test("with no helper, a long-quiet transcript is dead")
    func quietTranscriptIsDead() {
        let home = CoworkHome(withSubagent: false)
        home.backdateTranscript(by: 30 * 60)
        let hint = adapter.probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.home)
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("quiet"))
    }

    @Test("the minutes in between are unknown, not a guess")
    func inBetweenIsUnknown() {
        let home = CoworkHome(withSubagent: false)
        home.backdateTranscript(by: 5 * 60)
        let hint = adapter.probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.home)
        #expect(hint.verdict == .unknown)
    }

    @Test("a transcript that cannot be stat'd is unknown, not dead")
    func missingTranscriptIsUnknown() {
        let home = CoworkHome(withSubagent: false)
        let identity = SessionIdentity(
            key: coworkKey, sourcePath: home.projectDirectory.appendingPathComponent("gone.jsonl").path)
        let hint = adapter.probeLiveness(
            identity, table: FakeProcessTable(records: []), home: home.home)
        #expect(hint.verdict == .unknown)
    }
}
