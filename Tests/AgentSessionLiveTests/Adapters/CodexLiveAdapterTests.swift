import AgentSessionKit
import Darwin
import Foundation
import Testing

@testable import AgentSessionLive

// MARK: - Fixtures

/// The rollout fixture's own thread, and the ancestor whose header it
/// replays. Both are in `Fixtures/codex/rollout.jsonl`.
private let rolloutSession = SessionKey(
    harness: .codex, sessionID: "11111111-2222-3333-4444-555555555555")
private let childSession = SessionKey(
    harness: .codex, sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

/// A fixed observation clock, so nothing in the suite depends on today.
private let observed = Date(timeIntervalSince1970: 1_800_000_000)

private func fixture(_ name: String) throws -> URL {
    let url = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/codex/\(name)")
    try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
    return url
}

private func fixtureLines(_ name: String) throws -> [Data] {
    let text = try String(contentsOf: fixture(name), encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

private func mapped(_ name: String, as key: SessionKey = rolloutSession) throws -> [AgentEvent] {
    try fixtureLines(name).flatMap {
        CodexRecordMapper.events(from: $0, session: key, now: observed)
    }
}

/// A stable label per event case, for counting a whole file at once.
private func label(_ kind: AgentEventKind) -> String {
    switch kind {
    case .sessionStarted: "sessionStarted"
    case .identityUpdated: "identityUpdated"
    case .userPrompt: "userPrompt"
    case .turnStarted: "turnStarted"
    case .thinking: "thinking"
    case .assistantText: "assistantText"
    case .toolCallStarted: "toolCallStarted"
    case .toolCallFinished: "toolCallFinished"
    case .permissionRequested: "permissionRequested"
    case .permissionResolved: "permissionResolved"
    case .subagentStarted: "subagentStarted"
    case .subagentFinished: "subagentFinished"
    case .turnEnded(let reason): "turnEnded.\(reason.rawValue)"
    case .usage: "usage"
    case .compaction: "compaction"
    case .sessionEnded: "sessionEnded"
    case .liveness: "liveness"
    case .note: "note"
    case .textBody(let role, _, _): "textBody.\(role.rawValue)"
    }
}

private func histogram(_ events: [AgentEvent]) -> [String: Int] {
    events.reduce(into: [:]) { $0[label($1.kind), default: 0] += 1 }
}

private func starts(_ events: [AgentEvent]) -> [(id: String, name: String, kind: ToolKind, target: String?)] {
    events.compactMap {
        guard case let .toolCallStarted(id, name, kind, target) = $0.kind else { return nil }
        return (id, name, kind, target)
    }
}

private func start(_ events: [AgentEvent], named name: String)
    -> (id: String, name: String, kind: ToolKind, target: String?)? {
    starts(events).first { $0.name == name }
}

// MARK: - Mapper: the rollout

@Suite("CodexRecordMapper over a rollout")
struct CodexRolloutMapperTests {
    @Test("every record kind in the fixture lands on the event it should")
    func census() throws {
        let events = try mapped("rollout.jsonl")
        let counts = histogram(events)

        // Two headers, one of them a fork ancestor that must be skipped, plus
        // one `turn_context`.
        #expect(counts["identityUpdated"] == 2)
        // Two `user_message` records. The two user-role `response_item`s carry
        // the same text and are deliberately not counted again.
        #expect(counts["userPrompt"] == 2)
        #expect(counts["textBody.user"] == 2)
        #expect(counts["turnStarted"] == 2)
        // Three `reasoning` items plus one `agent_reasoning`.
        #expect(counts["thinking"] == 4)
        // Two assistant messages; the matching `agent_message` records are the
        // dedupe's losing half.
        #expect(counts["assistantText"] == 2)
        #expect(counts["textBody.assistant"] == 2)
        #expect(counts["turnEnded.complete"] == 2)
        #expect(counts["usage"] == 3)
        // `context_compacted` and the top-level `compacted` envelope.
        #expect(counts["compaction"] == 2)
        // Four `response_item` calls, plus the four `*_end` events whose work
        // has no `response_item` of its own.
        #expect(counts["toolCallStarted"] == 8)
        #expect(counts["toolCallFinished"] == 8)
        #expect(counts["textBody.toolResult"] == 4)
        // Nothing in this fixture blocks on a person or spawns a child.
        #expect(counts["permissionRequested"] == nil)
        #expect(counts["subagentStarted"] == nil)
        #expect(counts["note"] == nil)
        #expect(counts["sessionStarted"] == nil)
    }

    @Test("a desktop exec script becomes a shell call with the command it ran")
    func sandboxExec() throws {
        let events = try mapped("rollout.jsonl")
        let call = try #require(starts(events).first { $0.id == "call_0001" })
        #expect(call.name == "exec")
        #expect(call.kind == .shell)
        #expect(call.target == "swift test --filter TailerTests")

        let finished = events.compactMap { event -> Bool? in
            guard case let .toolCallFinished(id, isError) = event.kind, id == "call_0001"
            else { return nil }
            return isError
        }
        #expect(finished == [false])
    }

    @Test("an exec_command_end that repeats a response_item is dropped")
    func endEventsDoNotDoubleCount() throws {
        let events = try mapped("rollout.jsonl")
        // `exec_command_end` carries `call_0001`, which the `custom_tool_call`
        // already opened. One start, not two.
        #expect(starts(events).filter { $0.id == "call_0001" }.count == 1)
    }

    @Test("a patch applied inside a sandbox script is the only record of the write")
    func patchApplyEnd() throws {
        let events = try mapped("rollout.jsonl")
        let call = try #require(starts(events).first { $0.name == "apply_patch" })
        #expect(call.id == "exec-aaaa1111-bbbb-4ccc-8ddd-eeeeeeee0001")
        #expect(call.kind == .fileWrite)
        #expect(call.target == "/Users/example/code/demo/Tests/TailerTests.swift")
    }

    @Test("web and MCP work done inside a script is expanded too")
    func sandboxSideEffects() throws {
        let events = try mapped("rollout.jsonl")

        let search = try #require(start(events, named: "web_search"))
        #expect(search.kind == .web)
        #expect(search.target == "swift testing async expectations")

        let mcp = starts(events).filter { $0.kind == .mcp }
        #expect(mcp.count == 2)
        #expect(mcp.allSatisfy { $0.name == "node_repl.js" && $0.target == "node_repl" })

        // The second MCP call came back `isError: true` inside an `Ok`.
        let mcpFailures = events.compactMap { event -> String? in
            guard case let .toolCallFinished(id, isError) = event.kind, isError,
                  id.hasPrefix("exec-")
            else { return nil }
            return id
        }
        #expect(mcpFailures == ["exec-aaaa1111-bbbb-4ccc-8ddd-eeeeeeee0004"])
    }

    @Test("a tool result that exited non-zero is an error")
    func failingOutput() throws {
        let events = try mapped("rollout.jsonl")
        let finished = events.compactMap { event -> (String, Bool)? in
            guard case let .toolCallFinished(id, isError) = event.kind else { return nil }
            return (id, isError)
        }
        #expect(finished.contains { $0.0 == "call_0004" && $0.1 })
    }

    @Test("token counts are the per-step deltas, not the running totals")
    func usageDeltas() throws {
        let events = try mapped("rollout.jsonl")
        let usage = events.compactMap { event -> (Int, Int, Int)? in
            guard case let .usage(_, input, output, cached) = event.kind else { return nil }
            return (input, output, cached)
        }
        // The fixture's three `last_token_usage` blocks.
        #expect(usage.map(\.0) == [1200, 1800, 1400])
        #expect(usage.map(\.1) == [90, 120, 90])
        #expect(usage.map(\.2) == [400, 700, 500])
        // The last record's *totals* are 4400/300 — a mapper reading those
        // would bill the session three times over.
        #expect(usage.map(\.0).reduce(0, +) == 4400)
    }

    @Test("the header seeds the cwd, and a fork ancestor's header does not")
    func headerIdentity() throws {
        let events = try mapped("rollout.jsonl")
        let patches = events.compactMap { event -> SessionIdentityPatch? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch
        }
        #expect(patches.compactMap(\.cwd) == ["/Users/example/code/demo", "/Users/example/code/demo"])
        #expect(patches.contains { $0.cwd == "/Users/example/code/older" } == false)
        #expect(patches.compactMap(\.variant) == ["Codex Desktop"])
        #expect(patches.compactMap(\.entrypoint) == ["vscode"])
        #expect(patches.compactMap(\.model) == ["example-model-large"])
    }

    @Test("prompts and replies arrive as previews with full bodies alongside")
    func textBodies() throws {
        let events = try mapped("rollout.jsonl")
        let prompts = events.compactMap { event -> String? in
            guard case let .userPrompt(preview) = event.kind else { return nil }
            return preview
        }
        #expect(prompts.first == "Add a regression test for the JSONL tailer.")

        let bodies = events.compactMap { event -> (TextBodyRole, String, String?)? in
            guard case let .textBody(role, text, callID) = event.kind else { return nil }
            return (role, text, callID)
        }
        #expect(bodies.first { $0.0 == .user }?.1 == "Add a regression test for the JSONL tailer.")
        #expect(bodies.filter { $0.0 == .toolResult }.allSatisfy { $0.2 != nil })
        // The CLI wraps a result in a JSON envelope; the body is the output,
        // not the envelope.
        #expect(bodies.contains { $0.2 == "call_0004" && $0.1 == "error: no such module 'Testing'" })
    }

    @Test("a body longer than the limit is cut on a character boundary")
    func bodyCap() throws {
        // Two bytes per character, so the cap lands mid-character on a naive
        // byte slice.
        let long = String(repeating: "é", count: AgentEventKind.textBodyLimit)
        let capped = try #require(CodexRecordMapper.body(long))
        #expect(capped.utf8.count == AgentEventKind.textBodyLimit)
        #expect(capped.contains("\u{FFFD}") == false)
        #expect(CodexRecordMapper.body("") == nil)
    }
}

// MARK: - Mapper: CLI-shaped records

@Suite("CodexRecordMapper over CLI tool calls")
struct CodexCLIShapeTests {
    @Test("every CLI tool name lands on the kind a board groups by")
    func toolKinds() throws {
        let events = try mapped(
            "cli-shapes.jsonl",
            as: SessionKey(harness: .codex, sessionID: "55555555-6666-7777-8888-999999999999")
        )
        let byName = Dictionary(
            starts(events).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(byName["shell"]?.kind == .shell)
        #expect(byName["shell"]?.target == "bash -lc rg -n TODO Sources")
        #expect(byName["local_shell"]?.kind == .shell)
        #expect(byName["apply_patch"]?.kind == .fileWrite)
        #expect(byName["apply_patch"]?.target == "/Users/example/code/demo/Sources/App/Main.swift")
        #expect(byName["read_file"]?.kind == .fileRead)
        #expect(byName["read_file"]?.target == "/Users/example/code/demo/Sources/App/Main.swift")
        #expect(byName["grep"]?.kind == .search)
        #expect(byName["grep"]?.target == "Tailer")
        #expect(byName["web_search"]?.kind == .web)
        #expect(byName["spawn_agent"]?.kind == .subagent)
        #expect(byName["spawn_agent"]?.target == "Review the tailer change for rotation handling.")
        #expect(byName["mcp__example_server__list_items"]?.kind == .mcp)
        #expect(byName["wait_agent"]?.kind == .other)
        #expect(byName["tool_search"]?.kind == .search)
        #expect(byName["image_generation"]?.kind == .other)
    }

    @Test("a one-item web search opens and closes on the same record")
    func oneShotCalls() throws {
        let events = try mapped(
            "cli-shapes.jsonl",
            as: SessionKey(harness: .codex, sessionID: "55555555-6666-7777-8888-999999999999")
        )
        let openIDs = Set(starts(events).map(\.id))
        let closeIDs = Set(
            events.compactMap { event -> String? in
                guard case let .toolCallFinished(id, _) = event.kind else { return nil }
                return id
            })
        // `read_file`, `grep`, `web_search`, `spawn_agent`, the MCP call,
        // `local_shell`, and `wait_agent` have no output record in the fixture;
        // everything else is closed.
        #expect(closeIDs.isSubset(of: openIDs))
        #expect(closeIDs.contains("ws_2001"))
        #expect(closeIDs.contains("ig_2001"))
        #expect(closeIDs.contains("call_2010"))
    }

    @Test("a non-zero exit code inside a JSON output string is a failure")
    func exitCodes() throws {
        let events = try mapped(
            "cli-shapes.jsonl",
            as: SessionKey(harness: .codex, sessionID: "55555555-6666-7777-8888-999999999999")
        )
        let byID = Dictionary(
            events.compactMap { event -> (String, Bool)? in
                guard case let .toolCallFinished(id, isError) = event.kind else { return nil }
                return (id, isError)
            }, uniquingKeysWith: { first, _ in first })
        #expect(byID["call_2001"] == false)
        #expect(byID["call_2002"] == true)
        #expect(byID["call_2003"] == false)
    }
}

// MARK: - Mapper: the event sampler

@Suite("CodexRecordMapper over the event sampler")
struct CodexEventSamplerTests {
    @Test("a sub-agent starting and ending moves the child in and out")
    func subAgents() throws {
        let events = try mapped("events-sampler.jsonl")

        let started = events.compactMap { event -> (SessionKey, String?, String?)? in
            guard case let .subagentStarted(child, type, toolUse) = event.kind else { return nil }
            return (child, type, toolUse)
        }
        #expect(started.count == 2)
        #expect(started.first?.0 == childSession)
        #expect(started.first?.1 == "review_the_diff")
        #expect(started.first?.2 == "call_sub0001")
        // `collab_agent_spawn_end` carries a thread id, so it opens a child too.
        #expect(started.last?.0.sessionID == "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")

        let finished = events.compactMap { event -> SessionKey? in
            guard case let .subagentFinished(child) = event.kind else { return nil }
            return child
        }
        #expect(finished == [childSession])

        // `interacted` and `interrupted` are not endings — the corpus shows a
        // thread answering again after an interrupt.
        let notes = events.compactMap { event -> String? in
            guard case let .note(text) = event.kind else { return nil }
            return text
        }
        #expect(notes.contains("sub-agent interacted: review_the_diff"))
        #expect(notes.contains("sub-agent interrupted: review_the_diff"))
    }

    @Test("a guardian assessment is a permission request and its answer")
    func guardian() throws {
        let events = try mapped("events-sampler.jsonl")
        let requests = events.compactMap { event -> (String, String?)? in
            guard case let .permissionRequested(id, tool) = event.kind else { return nil }
            return (id, tool)
        }
        #expect(requests.map(\.1) == ["apply_patch", "command"])

        let answers = events.compactMap { event -> (String, Bool)? in
            guard case let .permissionResolved(id, allowed) = event.kind else { return nil }
            return (id, allowed)
        }
        #expect(answers.map(\.1) == [true, false])
        #expect(answers.map(\.0) == requests.map(\.0))
    }

    @Test("turn endings, titles, compaction, and errors")
    func remainingKinds() throws {
        let events = try mapped("events-sampler.jsonl")
        let counts = histogram(events)
        #expect(counts["turnEnded.aborted"] == 1)
        #expect(counts["turnEnded.complete"] == 1)
        #expect(counts["turnStarted"] == 1)
        #expect(counts["compaction"] == 1)

        let titles = events.compactMap { event -> String? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch.title
        }
        #expect(titles == ["Tailer rotation fix"])

        // An error is mid-turn: the turn closes on its own record, not this one.
        let notes = events.compactMap { event -> String? in
            guard case let .note(text) = event.kind else { return nil }
            return text
        }
        #expect(notes.contains { $0.hasPrefix("error: exceeded retry limit") })
    }

    @Test("a sub-agent's own header names it, and its parent's header does not win")
    func headerOfASpawnedThread() throws {
        let guardianKey = SessionKey(harness: .codex, sessionID: "22222222-3333-4444-5555-666666666666")
        let events = try mapped("events-sampler.jsonl", as: guardianKey)
        let patches = events.compactMap { event -> SessionIdentityPatch? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch
        }
        // Only the guardian's own header applies; the root thread's is skipped.
        // `source` is an object there, and its key names the flavour.
        #expect(patches.compactMap(\.entrypoint) == ["subagent"])
    }

    @Test("records with nothing to say about a session produce nothing")
    func ignoredRecords() throws {
        for line in try fixtureLines("events-sampler.jsonl") {
            guard let record = CodexRolloutRecord.decode(line) else { continue }
            let ignorable = ["thread_settings_applied", "item_completed", "thread_rolled_back"]
            guard record.type == "inter_agent_communication_metadata"
                || (record.payloadType.map(ignorable.contains) == true)
            else { continue }
            #expect(
                CodexRecordMapper.events(from: record, session: rolloutSession, now: observed)
                    .isEmpty)
        }
    }
}

// MARK: - Reducer integration

@Suite("Codex events through the reducer")
struct CodexReducerIntegrationTests {
    @Test("a whole rollout folds into an idle session with tool calls counted")
    func rolloutSnapshot() throws {
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: rolloutSession, sourcePath: "/Users/example/rollout.jsonl"))
        for event in try mapped("rollout.jsonl") {
            snapshot = reducer.reduce(snapshot, event: event)
        }

        #expect(snapshot.state == .idle)
        #expect(snapshot.turnCount == 2)
        #expect(snapshot.toolCallCount == 8)
        #expect(snapshot.identity.cwd == "/Users/example/code/demo")
        #expect(snapshot.identity.model == "example-model-large")
        #expect(snapshot.identity.variant == "Codex Desktop")
        #expect(snapshot.tokensIn == 4400)
        #expect(snapshot.tokensOut == 300)
        #expect(snapshot.tokensCached == 1600)
        #expect(snapshot.pending.openToolCalls.isEmpty)
    }

    @Test("a guardian request blocks the session and its answer clears it")
    func permissionCycle() throws {
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: rolloutSession, sourcePath: "/Users/example/rollout.jsonl"))
        var sawWaiting = false

        for event in try mapped("events-sampler.jsonl") {
            snapshot = reducer.reduce(snapshot, event: event)
            if case .waitingPermission = snapshot.state { sawWaiting = true }
        }

        #expect(sawWaiting)
        #expect(snapshot.pending.openPermission == nil)
        if case .waitingPermission = snapshot.state {
            Issue.record("the session is still blocked after both answers arrived")
        }
        // The sub-agent that never ended is still counted against the parent.
        #expect(snapshot.children.count == 2)
    }
}

// MARK: - Discovery, tailing, liveness

/// `flock(2)`, reached by symbol because Swift's `flock` names the `struct`
/// that `fcntl` takes. Same technique as `LockFileProbeTests`; an in-process
/// lock is enough here because the adapter only asks *whether* the lock is
/// held.
private let bsdFlock: @convention(c) (Int32, Int32) -> Int32 = {
    let handle = dlopen(nil, RTLD_NOW)
    return unsafeBitCast(dlsym(handle, "flock"), to: (@convention(c) (Int32, Int32) -> Int32).self)
}()

/// A synthetic `~/.codex` tree.
private struct CodexHome {
    let tree: TemporaryTree

    var path: String { tree.path }

    /// Writes a rollout under `sessions/<year>/<month>/<day>/`.
    @discardableResult
    func rollout(
        sessionID: String,
        day: (year: Int, month: Int, day: Int),
        stamp: String = "2026-01-01T00-00-00",
        contents: String = "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"SID\",\"session_id\":\"SID\",\"cwd\":\"/Users/example/code/demo\",\"originator\":\"codex_cli_rs\",\"source\":\"cli\"}}\n"
    ) -> URL {
        let name = String(
            format: ".codex/sessions/%04d/%02d/%02d/rollout-%@-%@.jsonl",
            day.year, day.month, day.day, stamp, sessionID)
        return tree.write(contents.replacingOccurrences(of: "SID", with: sessionID), to: name)
    }

    /// Creates the writer lock for a thread and returns its open descriptor.
    func lockFile(sessionID: String) -> Int32 {
        tree.write("", to: ".codex/thread-writer-locks/\(sessionID).lock")
        return open(CodexLiveAdapter.lockPath(home: path, sessionID: sessionID), O_RDWR)
    }
}

@Suite("CodexLiveAdapter", .serialized)
struct CodexLiveAdapterDiscoveryTests {
    private static let live = "11111111-2222-3333-4444-555555555555"
    private static let stale = "99999999-8888-7777-6666-555555555555"

    @Test("watch roots are the two rollout trees and the lock directory")
    func watchRoots() {
        let roots = CodexLiveAdapter().watchRoots(home: "/Users/example").map(\.path)
        #expect(roots == [
            "/Users/example/.codex/sessions",
            "/Users/example/.codex/archived_sessions",
            "/Users/example/.codex/thread-writer-locks"
        ])
    }

    @Test("a recent rollout is discovered and an old date directory is skipped")
    func discoveryWindow() async throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        home.rollout(
            sessionID: Self.live,
            day: (today.year ?? 2026, today.month ?? 1, today.day ?? 1))
        // Written a moment ago, but filed under a date three years back: the
        // directory name is what discovery reads, and it never opens the file.
        home.rollout(sessionID: Self.stale, day: (2020, 1, 1))

        let sources = try await CodexLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))

        #expect(sources.map(\.key.sessionID) == [Self.live])
        let seed = try #require(sources.first?.seedIdentity)
        #expect(seed.cwd == "/Users/example/code/demo")
        #expect(seed.variant == "codex_cli_rs")
        #expect(seed.entrypoint == "cli")
        #expect(seed.pid == nil)
        #expect(seed.procStart == nil)
    }

    @Test("a held writer lock overrides the window, however old the rollout is")
    func lockedSessionsAreAlwaysDiscovered() async throws {
        let home = CodexHome(tree: TemporaryTree())
        home.rollout(sessionID: Self.stale, day: (2020, 1, 1))
        let descriptor = home.lockFile(sessionID: Self.stale)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(bsdFlock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let sources = try await CodexLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        #expect(sources.map(\.key.sessionID) == [Self.stale])

        _ = bsdFlock(descriptor, LOCK_UN)
        let afterRelease = try await CodexLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        #expect(afterRelease.isEmpty)
    }

    @Test("a rollout whose header names a different thread is refused")
    func headerMismatch() async throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = (today.year ?? 2026, today.month ?? 1, today.day ?? 1)
        home.rollout(
            sessionID: Self.live,
            day: day,
            contents: """
                {"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"\(Self.stale)","cwd":"/Users/example/code/demo"}}

                """)

        let sources = try await CodexLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        #expect(sources.isEmpty)
    }

    @Test("a child discovered after its parent's transcript carries the parent")
    func subagentLinking() async throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = (today.year ?? 2026, today.month ?? 1, today.day ?? 1)
        home.rollout(sessionID: childSession.sessionID, day: day)

        let linker = CodexSubagentLinker()
        let adapter = CodexLiveAdapter(linker: linker)

        // Before the parent has been read, the child is parentless.
        let orphan = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        #expect(orphan.first?.seedIdentity.parent == nil)

        // Feed the parent's spawn record through a tailer, exactly as ingest
        // would.
        let parentPath = home.rollout(sessionID: Self.live, day: day).path
        let parentSource = SessionSource(
            key: rolloutSession,
            primaryPath: parentPath,
            seedIdentity: SessionIdentity(key: rolloutSession, sourcePath: parentPath))
        let spawn = """
            {"timestamp":"2026-01-01T00:00:05.000Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_sub0001","agent_thread_id":"\(childSession.sessionID)","agent_path":"/root/review_the_diff","kind":"started"}}

            """
        try Data(spawn.utf8).write(to: URL(fileURLWithPath: parentPath))
        _ = try await adapter.makeTailer(parentSource, cursor: nil).poll()
        #expect(linker.count == 1)

        let linked = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        let child = try #require(linked.first { $0.key == childSession })
        #expect(child.seedIdentity.parent == rolloutSession)
        #expect(child.seedIdentity.parentLink == .subagent(toolUseID: "call_sub0001"))
    }

    @Test("a spawned thread's own header names the thread it belongs to")
    func headerParentFallback() async throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = (today.year ?? 2026, today.month ?? 1, today.day ?? 1)
        let guardianID = "22222222-3333-4444-5555-666666666666"
        home.rollout(
            sessionID: guardianID,
            day: day,
            contents: """
                {"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"\(guardianID)","session_id":"\(Self.live)","cwd":"/Users/example/code/demo","source":{"subagent":{"other":"guardian"}}}}

                """)

        let sources = try await CodexLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3600))
        let seed = try #require(sources.first?.seedIdentity)
        #expect(seed.parent == SessionKey(harness: .codex, sessionID: Self.live))
        #expect(seed.parentLink == .subagent(toolUseID: nil))
        #expect(seed.entrypoint == "subagent")
    }

    @Test("the tailer produces exactly what the mapper does")
    func tailerMatchesMapper() async throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let contents = try String(contentsOf: fixture("rollout.jsonl"), encoding: .utf8)
        let path = home.rollout(
            sessionID: Self.live,
            day: (today.year ?? 2026, today.month ?? 1, today.day ?? 1),
            contents: contents
        ).path

        let source = SessionSource(
            key: rolloutSession,
            primaryPath: path,
            seedIdentity: SessionIdentity(key: rolloutSession, sourcePath: path))
        let tailed = try await CodexLiveAdapter().makeTailer(source, cursor: nil).poll()
        let direct = try mapped("rollout.jsonl")

        #expect(tailed.map { label($0.kind) } == direct.map { label($0.kind) })
        #expect(tailed.map(\.kind) == direct.map(\.kind))
        // The tailer owns the ordering and the back-reference; the mapper
        // leaves both to it.
        #expect(tailed.map(\.sequence) == Array(1...Int64(tailed.count)))
        #expect(tailed.allSatisfy { $0.raw?.path == path })
    }
}

@Suite("CodexLiveAdapter liveness", .serialized)
struct CodexLivenessTests {
    private static let sessionID = "11111111-2222-3333-4444-555555555555"

    private func identity(_ home: CodexHome, path: String) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: .codex, sessionID: Self.sessionID), sourcePath: path)
    }

    @Test("a held lock is alive, a released one is dead")
    func lockDrivesTheVerdict() throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let path = home.rollout(
            sessionID: Self.sessionID,
            day: (today.year ?? 2026, today.month ?? 1, today.day ?? 1)
        ).path
        let adapter = CodexLiveAdapter()
        let table = FakeProcessTable(records: [])
        let subject = identity(home, path: path)

        let descriptor = home.lockFile(sessionID: Self.sessionID)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(bsdFlock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let held = adapter.probeLiveness(subject, table: table, home: home.path)
        #expect(held.verdict == .alive)
        // Codex is Rust: its lock is a `flock(2)` and the kernel names no owner.
        #expect(held.pid == nil)
        #expect(held.evidence.contains("held"))

        _ = bsdFlock(descriptor, LOCK_UN)
        let released = adapter.probeLiveness(subject, table: table, home: home.path)
        #expect(released.verdict == .dead)
    }

    @Test("with no lock file at all, the rollout's age decides")
    func mtimeFallback() throws {
        let home = CodexHome(tree: TemporaryTree())
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let path = home.rollout(
            sessionID: Self.sessionID,
            day: (today.year ?? 2026, today.month ?? 1, today.day ?? 1)
        ).path
        let adapter = CodexLiveAdapter()
        let table = FakeProcessTable(records: [])
        let subject = identity(home, path: path)

        let fresh = adapter.probeLiveness(subject, table: table, home: home.path)
        #expect(fresh.verdict == .unknown)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path)
        let old = adapter.probeLiveness(subject, table: table, home: home.path)
        #expect(old.verdict == .dead)
        #expect(old.evidence.contains("untouched"))
    }

    @Test("a rollout that cannot be read at all answers unknown, never dead")
    func missingSource() {
        let home = CodexHome(tree: TemporaryTree())
        let hint = CodexLiveAdapter().probeLiveness(
            SessionIdentity(
                key: SessionKey(harness: .codex, sessionID: Self.sessionID),
                sourcePath: home.tree.file("gone.jsonl").path),
            table: FakeProcessTable(records: []),
            home: home.path)
        #expect(hint.verdict == .unknown)
    }
}
