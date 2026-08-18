import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

/// The event model is persisted and streamed, so its `Codable` conformance
/// is load-bearing. ``AgentEventKind`` and ``SessionState`` rely on Swift's
/// synthesized conformance for enums *with associated values*, which is the
/// part worth proving rather than assuming.
@Suite("Codable round-trips")
struct EventCodableTests {
    /// Every case of ``AgentEventKind``. A case added without a line here
    /// makes `everyEventKindIsCovered` fail.
    static let allEventKinds: [AgentEventKind] = [
        .sessionStarted(identity: richIdentity()),
        .identityUpdated(SessionIdentityPatch(
            cwd: "/Users/example/code/demo",
            gitBranch: "feat/live-events",
            title: "Wire up the reducer",
            model: "claude-opus-5",
            pid: 4711,
            procStart: epoch,
            entrypoint: "terminal",
            variant: "cli"
        )),
        .userPrompt(preview: "add a test for the reducer"),
        .turnStarted,
        .thinking,
        .assistantText(preview: "I'll start with the transition table."),
        .toolCallStarted(id: "toolu_1", name: "Bash", kind: .shell, target: "swift test"),
        .toolCallStarted(id: "toolu_2", name: "Write", kind: .fileWrite, target: nil),
        .toolCallFinished(id: "toolu_1", isError: false),
        .toolCallFinished(id: "toolu_2", isError: true),
        .permissionRequested(id: "perm_1", tool: "Bash"),
        .permissionRequested(id: "perm_2", tool: nil),
        .permissionResolved(id: "perm_1", allowed: true),
        .permissionResolved(id: "perm_2", allowed: false),
        .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "toolu_3"),
        .subagentStarted(child: childKey, agentType: nil, toolUseID: nil),
        .subagentFinished(child: childKey),
        .turnEnded(reason: .complete),
        .turnEnded(reason: .aborted),
        .turnEnded(reason: .error),
        .turnEnded(reason: .unknown),
        .usage(model: "claude-opus-5", inputTokens: 1_200, outputTokens: 340, cachedTokens: 8_000),
        .usage(model: nil, inputTokens: 0, outputTokens: 0, cachedTokens: 0),
        .compaction,
        .sessionEnded(reason: .exited),
        .sessionEnded(reason: .killed),
        .sessionEnded(reason: .processGone),
        .sessionEnded(reason: .unknown),
        .liveness(alive: true),
        .liveness(alive: false),
        .note("phase: planning"),
        .textBody(role: .user, text: "please refactor the parser", toolCallID: nil),
        .textBody(role: .assistant, text: "Done — see the diff.", toolCallID: nil),
        .textBody(role: .toolResult, text: "exit 0", toolCallID: "toolu_01"),
    ]

    static func richIdentity() -> SessionIdentity {
        SessionIdentity(
            key: parentKey,
            sourcePath: "/Users/example/.claude/projects/demo/session.jsonl",
            variant: "cli",
            parent: childKey,
            parentLink: .subagent(toolUseID: "toolu_9"),
            cwd: "/Users/example/code/demo",
            gitRoot: "/Users/example/code/demo",
            worktreePath: "/Users/example/code/demo/.agents/worktrees/feat-live-events",
            gitBranch: "feat/live-events",
            pid: 4711,
            procStart: epoch,
            title: "Wire up the reducer",
            model: "claude-opus-5",
            entrypoint: "terminal"
        )
    }

    @Test("every AgentEventKind case round-trips", arguments: Self.allEventKinds)
    func eventKindRoundTrip(_ kind: AgentEventKind) throws {
        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(AgentEventKind.self, from: data) == kind)
    }

    @Test("the case list covers the enum")
    func everyEventKindIsCovered() {
        // Every case appears at least once above; the switch is what makes
        // adding a case without adding a fixture a compile error.
        var seen = Set<String>()
        for kind in Self.allEventKinds {
            switch kind {
            case .sessionStarted: seen.insert("sessionStarted")
            case .identityUpdated: seen.insert("identityUpdated")
            case .userPrompt: seen.insert("userPrompt")
            case .turnStarted: seen.insert("turnStarted")
            case .thinking: seen.insert("thinking")
            case .assistantText: seen.insert("assistantText")
            case .toolCallStarted: seen.insert("toolCallStarted")
            case .toolCallFinished: seen.insert("toolCallFinished")
            case .permissionRequested: seen.insert("permissionRequested")
            case .permissionResolved: seen.insert("permissionResolved")
            case .subagentStarted: seen.insert("subagentStarted")
            case .subagentFinished: seen.insert("subagentFinished")
            case .turnEnded: seen.insert("turnEnded")
            case .usage: seen.insert("usage")
            case .compaction: seen.insert("compaction")
            case .sessionEnded: seen.insert("sessionEnded")
            case .liveness: seen.insert("liveness")
            case .note: seen.insert("note")
            case .textBody: seen.insert("textBody")
            }
        }
        #expect(seen.count == 19)
    }

    @Test("a whole event round-trips, id included")
    func eventRoundTrip() throws {
        let event = AgentEvent(
            session: parentKey,
            timestamp: epoch,
            observedAt: epoch.addingTimeInterval(12),
            sequence: 42,
            kind: .toolCallStarted(id: "toolu_1", name: "Bash", kind: .shell, target: "swift test"),
            raw: RawRef(path: "/Users/example/.claude/projects/demo/session.jsonl", byteOffset: 8_192, lineNumber: 31)
        )
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        #expect(decoded.id == event.id)
        #expect(decoded.raw?.rowID == nil)
    }

    @Test("observedAt defaults to the source timestamp")
    func observedAtDefault() {
        let event = AgentEvent(session: parentKey, timestamp: epoch, kind: .thinking)
        #expect(event.observedAt == epoch)
        #expect(event.sequence == 0)
        #expect(event.raw == nil)
    }

    @Test("two events describing the same record are distinct values")
    func idsAreNotStable() {
        let a = AgentEvent(session: parentKey, timestamp: epoch, kind: .thinking)
        let b = AgentEvent(session: parentKey, timestamp: epoch, kind: .thinking)
        #expect(a != b)
        #expect(a.kind == b.kind)
    }

    @Test("every SourceCursor case round-trips", arguments: [
        SourceCursor.byteOffset(inode: 8_675_309, offset: 1_048_576),
        .rowID(4_711),
        .blobHead("b3d1c0ffee"),
        .composite([
            "/Users/example/.grok/sessions/x/events.jsonl": .byteOffset(inode: 1, offset: 10),
            "/Users/example/.grok/sessions/x/updates.jsonl": .byteOffset(inode: 2, offset: 20),
        ]),
        .composite(["/Users/example/.cursor/chats/x/store.db": .rowID(3)]),
        .composite([:]),
    ])
    func cursorRoundTrip(_ cursor: SourceCursor) throws {
        let data = try JSONEncoder().encode(cursor)
        #expect(try JSONDecoder().decode(SourceCursor.self, from: data) == cursor)
    }

    @Test("a nested composite cursor round-trips")
    func nestedCompositeCursor() throws {
        let cursor = SourceCursor.composite([
            "a": .composite(["b": .rowID(1)]),
            "c": .blobHead("deadbeef"),
        ])
        let data = try JSONEncoder().encode(cursor)
        #expect(try JSONDecoder().decode(SourceCursor.self, from: data) == cursor)
    }

    @Test("every SessionState case round-trips", arguments: [
        SessionState.idle,
        .thinking,
        .toolCalling(name: "Bash"),
        .writingFile(path: "/Users/example/a.swift"),
        .writingFile(path: nil),
        .delegating(children: 3),
        .waitingPermission(tool: "Bash"),
        .waitingPermission(tool: nil),
        .ended(reason: .exited),
    ])
    func sessionStateRoundTrip(_ state: SessionState) throws {
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SessionState.self, from: data) == state)
    }

    @Test("a fully populated snapshot round-trips")
    func snapshotRoundTrip() throws {
        var harness = ReducerHarness()
        harness.send([
            .sessionStarted(identity: Self.richIdentity()),
            .userPrompt(preview: "investigate"),
            .toolCallStarted(id: "task-1", name: "Task", kind: .subagent, target: "Explore"),
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "task-1"),
            .subagentStarted(child: otherChildKey, agentType: "Explore", toolUseID: "task-1"),
            .subagentFinished(child: childKey),
            .permissionRequested(id: "perm_1", tool: "Bash"),
            .usage(model: "claude-opus-5", inputTokens: 1_200, outputTokens: 340, cachedTokens: 8_000),
        ])

        let snapshot = harness.snapshot
        #expect(snapshot.state == .waitingPermission(tool: "Bash"))
        #expect(!snapshot.pending.isEmpty)
        #expect(snapshot.children.count == 2)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test("identity and source descriptions round-trip")
    func sourceRoundTrip() throws {
        let source = SessionSource(
            key: parentKey,
            primaryPath: "/Users/example/.grok/sessions/x/updates.jsonl",
            auxiliaryPaths: ["/Users/example/.grok/sessions/x/events.jsonl"],
            seedIdentity: Self.richIdentity()
        )
        #expect(source.allPaths.count == 2)
        let decoded = try JSONDecoder().decode(SessionSource.self, from: JSONEncoder().encode(source))
        #expect(decoded == source)
    }

    @Test("liveness hints and process records round-trip")
    func livenessRoundTrip() throws {
        let hint = LivenessHint(verdict: .alive, pid: 4711, evidence: "matched pid 4711 started 12s before the first line")
        #expect(try JSONDecoder().decode(LivenessHint.self, from: JSONEncoder().encode(hint)) == hint)
        #expect(LivenessHint.unknown("no pid recorded").verdict == .unknown)

        let record = ProcessRecord(
            pid: 4711,
            ppid: 1,
            startTime: epoch,
            executable: "/usr/local/bin/cursor-agent",
            argv: ArgvSanitizer.sanitize(["cursor-agent", "--api-key", "crsr_0123456789abcdef"]),
            cwd: "/Users/example/code/demo"
        )
        #expect(record.argv.last == ArgvSanitizer.redactionPlaceholder)
        #expect(try JSONDecoder().decode(ProcessRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test("every ToolKind round-trips")
    func toolKindRoundTrip() throws {
        let data = try JSONEncoder().encode(ToolKind.allCases)
        #expect(try JSONDecoder().decode([ToolKind].self, from: data) == ToolKind.allCases)
    }

    @Test("the schema version is stamped")
    func schemaVersion() {
        #expect(AgentSessionLive.eventSchemaVersion == 1)
    }
}
