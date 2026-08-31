import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

// MARK: - A synthetic machine

/// `flock(2)`, reached by symbol because Swift's `flock` names the `struct`
/// that `fcntl` takes. An in-process lock is enough: the adapters only ask
/// *whether* one is held.
private let bsdFlock: @convention(c) (Int32, Int32) -> Int32 = {
    let handle = dlopen(nil, RTLD_NOW)
    return unsafeBitCast(dlsym(handle, "flock"), to: (@convention(c) (Int32, Int32) -> Int32).self)
}()

/// A home directory with a plausible amount of history in it, across every
/// store the live layer reads.
///
/// The shapes are the real ones — a Codex rollout really is
/// `<yyyy>/<MM>/<dd>/rollout-<stamp>-<uuid>.jsonl`, a Grok session really is a
/// directory of four files under a percent-encoded cwd — because what is being
/// measured is the *walk*, and the walk is decided entirely by the layout.
/// The contents are as thin as each adapter will accept: a discovery pass is
/// bounded head reads and stats, never a parse of a whole transcript, so the
/// cost of a transcript's body does not belong in this measurement.
struct SyntheticHome {
    let tree: TemporaryTree
    var path: String { tree.path }

    private static let stamp = "2026-08-19T13-58-51"

    /// A synthetic id in the 8-4-4-4-12 shape Codex reads a thread id out of
    /// a rollout's file name by.
    private func uuid(_ index: Int) -> String {
        let value = UInt32(truncatingIfNeeded: index)
        return String(format: "%08x-0000-4000-8000-%012x", value, value)
    }

    private func touch(_ url: URL, _ contents: String, modified: Date? = nil) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
        if let modified {
            try? FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    /// `~/.claude/projects/<project>/<session>.jsonl`, spread over `projects`
    /// directories, each with one subagent beside it.
    func claude(sessions: Int, projects: Int) {
        let root = URL(fileURLWithPath: path).appendingPathComponent(".claude/projects")
        for index in 0..<sessions {
            let project = root.appendingPathComponent("-Users-example-project-\(index % projects)")
            let id = uuid(index)
            touch(project.appendingPathComponent("\(id).jsonl"), """
                {"type":"user","uuid":"u\(index)","sessionId":"\(id)",\
                "cwd":"/Users/example/project-\(index % projects)",\
                "timestamp":"2026-08-19T05:58:51.000Z","gitBranch":"main","version":"2.0.0",\
                "message":{"role":"user","content":"hello"}}

                """)
            let subagents = project.appendingPathComponent(id).appendingPathComponent("subagents")
            touch(subagents.appendingPathComponent("agent-\(uuid(index + 900_000)).jsonl"), "")
            touch(
                subagents.appendingPathComponent("agent-\(uuid(index + 900_000)).meta.json"),
                #"{"agentType":"Explore","description":"look","toolUseId":"t\#(index)"}"#)
        }
    }

    /// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-…jsonl`, over `days` day
    /// directories — one recent, the rest years back, which is what makes the
    /// second pass expensive when it runs.
    func codex(rollouts: Int, days: Int) {
        let root = URL(fileURLWithPath: path).appendingPathComponent(CodexLiveAdapter.sessionsPath)
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        for index in 0..<rollouts {
            let id = uuid(index + 100_000)
            let day = root
                .appendingPathComponent(String(format: "%04d", today.year ?? 2026))
                .appendingPathComponent(String(format: "%02d", today.month ?? 8))
                .appendingPathComponent(String(format: "%02d", today.day ?? 19))
            touch(day.appendingPathComponent("rollout-\(Self.stamp)-\(id).jsonl"), """
                {"type":"session_meta","timestamp":"2026-08-19T05:58:51.000Z",\
                "payload":{"id":"\(id)","cwd":"/Users/example/work","originator":"codex_cli_rs"}}

                """)
        }
        // Empty history, walked by the second pass and by nothing else.
        for back in 1...days {
            let date = Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let day = root
                .appendingPathComponent(String(format: "%04d", parts.year ?? 2026))
                .appendingPathComponent(String(format: "%02d", parts.month ?? 8))
                .appendingPathComponent(String(format: "%02d", parts.day ?? 19))
            try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        }
    }

    /// A held writer lock whose thread has no rollout anywhere: the second
    /// pass's whole reason for existing, and what used to make it walk every
    /// year of history on every single sweep.
    ///
    /// The caller closes the returned descriptor; the lock lives exactly as
    /// long as it is open.
    func codexOrphanLock() throws -> Int32 {
        let file = URL(fileURLWithPath: path)
            .appendingPathComponent(CodexLiveAdapter.locksPath)
            .appendingPathComponent("\(uuid(999_999)).lock")
        touch(file, "")
        let descriptor = open(file.path, O_RDWR)
        try #require(descriptor >= 0)
        try #require(bsdFlock(descriptor, LOCK_EX | LOCK_NB) == 0)
        return descriptor
    }

    /// `~/.grok/sessions/<encoded cwd>/<id>/`, with `stale` of them written
    /// three hours before the cutoff — old enough to need the lock probe,
    /// recent enough to be inside the window where it is asked.
    func grok(sessions: Int, stale: Int, cutoff: Date) {
        let root = GrokLiveAdapter.sessionsRoot(home: path)
        for index in 0..<sessions {
            let project = root.appendingPathComponent("-Users-example-project-\(index % 8)")
            let directory = project.appendingPathComponent("session-\(uuid(index + 200_000))")
            let modified = index < stale ? cutoff.addingTimeInterval(-3 * 3600) : nil
            for name in ["events.jsonl", "updates.jsonl", "chat_history.jsonl"] {
                touch(directory.appendingPathComponent(name), "", modified: modified)
            }
            touch(
                directory.appendingPathComponent("summary.json"),
                #"{"info":{"id":"session-\#(uuid(index + 200_000))"},"generated_title":"a title"}"#,
                modified: modified)
            // One writer lock per mutable file, exactly as Grok leaves them.
            for name in ["events.jsonl.lock", "updates.jsonl.lock", "chat_history.jsonl.lock"] {
                touch(directory.appendingPathComponent(name), "", modified: modified)
            }
        }
    }

    /// `~/.cursor/chats/<workspace>/<agent>/{store.db,meta.json}`.
    func cursor(agents: Int, workspaces: Int) {
        let root = CursorPaths.chatsRoot(home: path)
        for index in 0..<agents {
            let directory = root
                .appendingPathComponent("workspace-\(index % workspaces)")
                .appendingPathComponent(uuid(index + 300_000))
            touch(directory.appendingPathComponent(CursorPaths.storeFileName), "SQLite format 3\0")
            touch(
                directory.appendingPathComponent(CursorPaths.metaFileName),
                #"{"schemaVersion":1,"cwd":"/Users/example/work","hasConversation":true}"#)
        }
    }

    /// `~/.gemini/antigravity-cli/conversations/<uuid>.db`.
    func antigravity(conversations: Int) {
        let root = AntigravityLiveAdapter.conversationsPath(
            home: path, root: AntigravityLiveAdapter.cliRoot)
        for index in 0..<conversations {
            touch(
                root.appendingPathComponent("\(uuid(index + 400_000)).db"),
                "SQLite format 3\0")
        }
    }
}

/// Every adapter, in one sweep, measured.
private func sweep(
    _ adapters: [any SourceAdapter],
    home: String,
    activeSince: Date
) async throws -> (sources: Int, cost: DiscoveryCounters, seconds: Double) {
    let started = ContinuousClock.now
    let result = try await DiscoveryIO.counting { () -> Int in
        var total = 0
        for adapter in adapters {
            total += try await adapter.discover(home: home, activeSince: activeSince).count
        }
        return total
    }
    let elapsed = (ContinuousClock.now - started).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    return (result.value, result.cost, seconds)
}

// MARK: - Cost

@Suite("Discovery cost")
struct DiscoveryCostTests {
    private func adapters() -> [any SourceAdapter] {
        [
            ClaudeLiveAdapter(),
            CodexLiveAdapter(),
            GrokLiveAdapter(),
            CursorLiveAdapter(),
            AntigravityLiveAdapter(),
        ]
    }

    @Test("a second sweep of a home with six hundred sessions reads nothing again")
    func secondSweepIsNearlyFree() async throws {
        let home = SyntheticHome(tree: TemporaryTree())
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        home.claude(sessions: 210, projects: 30)
        home.codex(rollouts: 200, days: 120)
        home.grok(sessions: 140, stale: 100, cutoff: cutoff)
        home.cursor(agents: 8, workspaces: 3)
        home.antigravity(conversations: 75)
        let lock = try home.codexOrphanLock()
        defer { close(lock) }

        let adapters = adapters()
        let first = try await sweep(adapters, home: home.path, activeSince: cutoff)
        let second = try await sweep(adapters, home: home.path, activeSince: cutoff)

        // The same board, twice.
        #expect(first.sources == second.sources)
        #expect(first.sources > 600)

        // Nothing changed on disk, so nothing has to be read or probed again.
        // These are the two costs that scale with how much history is on the
        // machine and with how many files a store keeps per session, and they
        // are the ones the sampler found the pipeline burning at rest.
        #expect(first.cost.fileReads > 600)
        #expect(second.cost.fileReads == 0)
        // The one probe left on the second sweep is Codex asking about the
        // orphan writer lock, which is not remembered on purpose: a lock is
        // released without leaving a trace on disk, and a thread that is
        // still holding one is the row a board must not lose.
        #expect(first.cost.lockProbes > 300)
        #expect(second.cost.lockProbes <= 2)

        // The walk itself is not cached — a sweep exists precisely to find
        // what nothing announced — but it is the cheap half, and the second
        // one is no more expensive than the first.
        #expect(second.cost.directoryListings <= first.cost.directoryListings)

        print(
            """
            [discovery] \(first.sources) sources across five stores
              first  sweep: \(first.cost.directoryListings) listings, \
            \(first.cost.lockProbes) lock probes, \(first.cost.fileReads) file reads, \
            \(String(format: "%.0f", first.seconds * 1000)) ms
              second sweep: \(second.cost.directoryListings) listings, \
            \(second.cost.lockProbes) lock probes, \(second.cost.fileReads) file reads, \
            \(String(format: "%.0f", second.seconds * 1000)) ms
            """)
    }

    @Test("a scoped sweep costs a fraction of a full one")
    func scopedSweepIsSmall() async throws {
        let home = SyntheticHome(tree: TemporaryTree())
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        home.claude(sessions: 210, projects: 30)

        let adapter = ClaudeLiveAdapter()
        let full = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        let project = URL(fileURLWithPath: home.path)
            .appendingPathComponent(".claude/projects/-Users-example-project-3")
        let scoped = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff, under: project)
        }

        // One project of thirty: its sessions, and the listings for them.
        #expect(scoped.value.count > 0)
        #expect(scoped.value.count < full.value.count / 4)
        #expect(scoped.cost.directoryListings < full.cost.directoryListings / 4)
        #expect(Set(scoped.value.map(\.primaryPath)).isSubset(of: Set(full.value.map(\.primaryPath))))
    }

    @Test("an unchanged Grok store is not probed for locks again")
    func grokLockProbesAreRemembered() async throws {
        let home = SyntheticHome(tree: TemporaryTree())
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        home.grok(sessions: 40, stale: 40, cutoff: cutoff)

        let adapter = GrokLiveAdapter()
        let first = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        // Forty sessions holding three lock files each, none of them locked.
        #expect(first.cost.lockProbes >= 40)
        #expect(first.value.isEmpty)

        let second = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        #expect(second.cost.lockProbes == 0)

        // Writing to a session is what makes the question live again — and
        // that session is now recent enough not to need the answer.
        let touched = GrokLiveAdapter.sessionsRoot(home: home.path)
            .appendingPathComponent("-Users-example-project-0")
        let session = try #require(
            DiscoveryIO.children(of: touched).first.map { $0.appendingPathComponent("events.jsonl") })
        try Data("{}\n".utf8).write(to: session)

        let third = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        #expect(third.value.count == 1)
        #expect(third.cost.lockProbes == 0)
    }

    @Test("an unchanged Codex store does not walk its history again")
    func codexSecondPassIsRemembered() async throws {
        let home = SyntheticHome(tree: TemporaryTree())
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        home.codex(rollouts: 20, days: 200)
        let lock = try home.codexOrphanLock()
        defer { close(lock) }

        let adapter = CodexLiveAdapter()
        let first = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        // Two hundred day directories walked for one lock nothing can resolve.
        #expect(first.cost.directoryListings > 200)

        let second = try await DiscoveryIO.counting {
            try await adapter.discover(home: home.path, activeSince: cutoff)
        }
        #expect(second.cost.directoryListings < first.cost.directoryListings / 2)
        #expect(second.cost.fileReads == 0)
        #expect(first.value.map(\.primaryPath) == second.value.map(\.primaryPath))
    }
}
