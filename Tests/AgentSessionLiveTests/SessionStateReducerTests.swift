import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("SessionStateReducer")
struct SessionStateReducerTests {
    // MARK: - Table-driven scenarios

    static let scenarios: [ReducerScenario] = [
        ReducerScenario(
            "simple turn",
            script: [
                .userPrompt(preview: "add a test"),
                .thinking,
                .assistantText(preview: "Sure."),
                .turnEnded(reason: .complete),
            ],
            expectedState: .idle
        ),
        ReducerScenario(
            "turn still running",
            script: [
                .userPrompt(preview: "add a test"),
                .thinking,
            ],
            expectedState: .thinking
        ),
        ReducerScenario(
            "tool call open",
            script: [
                .userPrompt(preview: "run the suite"),
                .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
            ],
            expectedState: .toolCalling(name: "Bash"),
            expectedToolCalls: 1
        ),
        ReducerScenario(
            "tool call finished hands the floor back to the model",
            script: [
                .userPrompt(preview: "run the suite"),
                .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
                .toolCallFinished(id: "t1", isError: false),
            ],
            expectedState: .thinking,
            expectedToolCalls: 1
        ),
        ReducerScenario(
            "file write is called out separately",
            script: [
                .userPrompt(preview: "fix the typo"),
                .toolCallStarted(id: "t1", name: "Edit", kind: .fileWrite, target: "/Users/example/a.swift"),
            ],
            expectedState: .writingFile(path: "/Users/example/a.swift"),
            expectedToolCalls: 1
        ),
        ReducerScenario(
            "nested tool call restores the outer one",
            script: [
                .userPrompt(preview: "refactor"),
                .toolCallStarted(id: "outer", name: "Task", kind: .subagent, target: nil),
                .toolCallStarted(id: "inner", name: "Read", kind: .fileRead, target: "/Users/example/a.swift"),
                .toolCallFinished(id: "inner", isError: false),
            ],
            expectedState: .delegating(children: 1),
            expectedToolCalls: 2
        ),
        ReducerScenario(
            "subagent running",
            script: [
                .userPrompt(preview: "explore"),
                .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
            ],
            expectedState: .delegating(children: 1)
        ),
        ReducerScenario(
            "two subagents running",
            script: [
                .userPrompt(preview: "explore"),
                .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
                .subagentStarted(child: otherChildKey, agentType: "Explore", toolUseID: "t2"),
            ],
            expectedState: .delegating(children: 2)
        ),
        ReducerScenario(
            "permission wait",
            script: [
                .userPrompt(preview: "delete the branch"),
                .permissionRequested(id: "p1", tool: "Bash"),
            ],
            expectedState: .waitingPermission(tool: "Bash")
        ),
        ReducerScenario(
            "permission allowed",
            script: [
                .userPrompt(preview: "delete the branch"),
                .permissionRequested(id: "p1", tool: "Bash"),
                .permissionResolved(id: "p1", allowed: true),
            ],
            expectedState: .thinking
        ),
        ReducerScenario(
            "permission denied leaves the same derived state as an allow",
            script: [
                .userPrompt(preview: "delete the branch"),
                .permissionRequested(id: "p1", tool: "Bash"),
                .permissionResolved(id: "p1", allowed: false),
            ],
            expectedState: .thinking
        ),
        ReducerScenario(
            "a tool call started while blocked does not unblock",
            script: [
                .userPrompt(preview: "delete the branch"),
                .permissionRequested(id: "p1", tool: "Bash"),
                .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "git branch -D x"),
            ],
            expectedState: .waitingPermission(tool: "Bash"),
            expectedToolCalls: 1
        ),
        ReducerScenario(
            "permission outranks a running child",
            script: [
                .userPrompt(preview: "explore then delete"),
                .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
                .permissionRequested(id: "p1", tool: "Bash"),
            ],
            expectedState: .waitingPermission(tool: "Bash")
        ),
        ReducerScenario(
            "abort closes the turn",
            script: [
                .userPrompt(preview: "run forever"),
                .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "sleep 9999"),
                .turnEnded(reason: .aborted),
            ],
            expectedState: .idle,
            expectedToolCalls: 1
        ),
        ReducerScenario(
            "a turn that ends with a child still running keeps delegating",
            script: [
                .userPrompt(preview: "explore"),
                .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
                .turnEnded(reason: .complete),
            ],
            expectedState: .delegating(children: 1)
        ),
        ReducerScenario(
            "session ended",
            script: [
                .userPrompt(preview: "bye"),
                .turnEnded(reason: .complete),
                .sessionEnded(reason: .exited),
            ],
            expectedState: .ended(reason: .exited),
            expectedAlive: false
        ),
        ReducerScenario(
            "liveness says the process is gone",
            script: [
                .userPrompt(preview: "run the suite"),
                .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
                .liveness(alive: false),
            ],
            expectedState: .ended(reason: .processGone),
            expectedToolCalls: 1,
            expectedAlive: false
        ),
        ReducerScenario(
            "resurrection after a process-gone verdict",
            script: [
                .userPrompt(preview: "run the suite"),
                .liveness(alive: false),
                .liveness(alive: true),
            ],
            expectedState: .idle
        ),
        ReducerScenario(
            "a compaction is only a heartbeat",
            script: [
                .userPrompt(preview: "keep going"),
                .compaction,
            ],
            expectedState: .thinking
        ),
        ReducerScenario(
            "a note is only a heartbeat",
            script: [
                .userPrompt(preview: "keep going"),
                .note("phase: planning"),
            ],
            expectedState: .thinking
        ),
    ]

    @Test("scripted sequences reach the expected state", arguments: Self.scenarios)
    func scenario(_ scenario: ReducerScenario) {
        var harness = ReducerHarness()
        harness.send(scenario.script)

        #expect(harness.state == scenario.expectedState, "\(scenario.name): state")
        #expect(harness.snapshot.turnCount == scenario.expectedTurns, "\(scenario.name): turns")
        #expect(harness.snapshot.toolCallCount == scenario.expectedToolCalls, "\(scenario.name): tool calls")
        #expect(harness.snapshot.isAlive == scenario.expectedAlive, "\(scenario.name): alive")
        #expect(harness.snapshot.lastEventAt == harness.clock, "\(scenario.name): heartbeat")
        #expect(harness.snapshot.isStale == false, "\(scenario.name): nothing goes stale in one second")
    }

    // MARK: - Session start and identity

    @Test("the initial snapshot is idle, alive, and empty")
    func initialSnapshot() {
        let snapshot = SessionStateReducer.initialSnapshot(identity: makeIdentity())
        #expect(snapshot.state == .idle)
        #expect(snapshot.isAlive)
        #expect(!snapshot.isStale)
        #expect(snapshot.pending.isEmpty)
        #expect(snapshot.lastEventAt == nil)
        #expect(snapshot.startedAt == nil)
        #expect(snapshot.turnCount == 0)
        #expect(snapshot.children.isEmpty)
        #expect(snapshot.key == parentKey)
    }

    @Test("sessionStarted adopts a matching identity and stamps the start")
    func sessionStarted() {
        var harness = ReducerHarness()
        var richer = makeIdentity()
        richer.model = "claude-opus-5"
        richer.gitBranch = "feat/live-events"

        harness.send(.sessionStarted(identity: richer))

        #expect(harness.state == .idle)
        #expect(harness.snapshot.identity.model == "claude-opus-5")
        #expect(harness.snapshot.identity.gitBranch == "feat/live-events")
        #expect(harness.snapshot.startedAt == harness.clock)
        #expect(harness.snapshot.endedAt == nil)
    }

    @Test("sessionStarted for a different key never rewrites the identity")
    func sessionStartedIgnoresForeignIdentity() {
        var harness = ReducerHarness()
        let foreign = SessionIdentity(key: childKey, sourcePath: "/Users/example/.codex/sessions/x.jsonl")

        harness.send(.sessionStarted(identity: foreign))

        #expect(harness.snapshot.identity.key == parentKey)
        #expect(harness.snapshot.identity.sourcePath.hasSuffix("session.jsonl"))
        #expect(harness.state == .idle)
    }

    @Test("the first event stamps startedAt when the session start was never seen")
    func startedAtFallsBackToFirstSighting() {
        var harness = ReducerHarness()
        harness.send(.assistantText(preview: "…continuing"))
        #expect(harness.snapshot.startedAt == harness.clock)
    }

    @Test("identityUpdated merges only the fields it carries")
    func identityPatchMerges() {
        var harness = ReducerHarness()
        harness.send(.identityUpdated(SessionIdentityPatch(model: "gpt-5.6", pid: 4711)))
        harness.send(.identityUpdated(SessionIdentityPatch(gitBranch: "main")))

        #expect(harness.snapshot.identity.model == "gpt-5.6")
        #expect(harness.snapshot.identity.pid == 4711)
        #expect(harness.snapshot.identity.gitBranch == "main")
        #expect(harness.snapshot.identity.cwd == "/Users/example/code/demo")
    }

    @Test("an empty patch changes nothing")
    func emptyPatch() {
        let patch = SessionIdentityPatch()
        #expect(patch.isEmpty)
        let identity = makeIdentity()
        #expect(patch.applied(to: identity) == identity)
    }

    // MARK: - Turns

    @Test("turnStarted after a prompt does not double-count the turn")
    func turnStartedDoesNotDoubleCount() {
        var harness = ReducerHarness()
        harness.send(.userPrompt(preview: "hello"))
        let openedAt = harness.clock
        harness.send(.turnStarted)

        #expect(harness.snapshot.turnCount == 1)
        #expect(harness.snapshot.pending.currentTurnStartedAt == openedAt)
    }

    @Test("turnStarted with no prompt opens a turn of its own")
    func turnStartedOpensATurn() {
        var harness = ReducerHarness()
        harness.send(.turnStarted)
        #expect(harness.snapshot.turnCount == 1)
        #expect(harness.state == .thinking)

        harness.send(.turnEnded(reason: .complete))
        harness.send(.turnStarted)
        #expect(harness.snapshot.turnCount == 2)
    }

    @Test("turnEnded clears orphaned tool calls but keeps the children")
    func turnEndedClearsOrphans() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "do three things"),
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "true"),
            .toolCallStarted(id: "t2", name: "Read", kind: .fileRead, target: "/Users/example/a.swift"),
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t3"),
            .permissionRequested(id: "p1", tool: "Bash"),
            .turnEnded(reason: .error),
        ])

        #expect(harness.snapshot.pending.openToolCalls.isEmpty)
        #expect(harness.snapshot.pending.openPermission == nil)
        #expect(harness.snapshot.pending.currentTurnStartedAt == nil)
        #expect(harness.snapshot.pending.openChildren == [childKey])
        #expect(harness.state == .delegating(children: 1))
    }

    // MARK: - Subagents

    @Test("children accumulate while openChildren tracks only the live ones")
    func childrenRoster() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "fan out"),
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
            .subagentStarted(child: otherChildKey, agentType: "Explore", toolUseID: "t2"),
            .subagentFinished(child: childKey),
        ])

        #expect(harness.snapshot.children == [childKey, otherChildKey])
        #expect(harness.snapshot.pending.openChildren == [otherChildKey])
        #expect(harness.state == .delegating(children: 1))

        harness.send(.subagentFinished(child: otherChildKey))
        #expect(harness.snapshot.children == [childKey, otherChildKey])
        #expect(harness.snapshot.pending.openChildren.isEmpty)
        #expect(harness.state == .thinking)
    }

    @Test("a child spawned twice is listed once")
    func duplicateChild() {
        var harness = ReducerHarness()
        harness.send([
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "t1"),
        ])
        #expect(harness.snapshot.children == [childKey])
        #expect(harness.state == .delegating(children: 1))
    }

    @Test("a nested subagent unwinds through the parent's open Task call")
    func nestedSubagent() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "investigate"),
            .toolCallStarted(id: "task-1", name: "Task", kind: .subagent, target: "Explore"),
            .subagentStarted(child: childKey, agentType: "Explore", toolUseID: "task-1"),
        ])
        #expect(harness.state == .delegating(children: 1))

        harness.send(.subagentFinished(child: childKey))
        // The Task tool call is still open even though the child is done.
        #expect(harness.state == .delegating(children: 1))
        #expect(harness.snapshot.pending.openToolCalls.keys.contains("task-1"))

        harness.send(.toolCallFinished(id: "task-1", isError: false))
        #expect(harness.state == .thinking)
        #expect(harness.snapshot.pending.isEmpty)

        harness.send(.turnEnded(reason: .complete))
        #expect(harness.state == .idle)
    }

    // MARK: - Permissions

    @Test("a resolution for a superseded prompt does not clear the live one")
    func permissionResolvedMatchesOnID() {
        var harness = ReducerHarness()
        harness.send([
            .permissionRequested(id: "p1", tool: "Bash"),
            .permissionRequested(id: "p2", tool: "Write"),
            .permissionResolved(id: "p1", allowed: true),
        ])

        #expect(harness.snapshot.pending.openPermission == PendingPermission(id: "p2", tool: "Write"))
        #expect(harness.state == .waitingPermission(tool: "Write"))

        harness.send(.permissionResolved(id: "p2", allowed: true))
        #expect(harness.snapshot.pending.openPermission == nil)
    }

    @Test("resolving a permission restores the tool call that was underneath it")
    func permissionResolvedRestoresToolCall() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "write the file"),
            .toolCallStarted(id: "t1", name: "Write", kind: .fileWrite, target: "/Users/example/a.swift"),
            .permissionRequested(id: "p1", tool: "Write"),
            .permissionResolved(id: "p1", allowed: true),
        ])
        #expect(harness.state == .writingFile(path: "/Users/example/a.swift"))
    }

    // MARK: - Liveness

    @Test("process gone, then resurrected")
    func processGoneThenResurrect() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "run the suite"),
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
        ])
        #expect(harness.state == .toolCalling(name: "Bash"))

        harness.send(.liveness(alive: false))
        let deathTime = harness.clock
        #expect(harness.state == .ended(reason: .processGone))
        #expect(harness.snapshot.isAlive == false)
        #expect(harness.snapshot.endedAt == deathTime)
        #expect(harness.snapshot.pending.isEmpty)

        harness.send(.liveness(alive: true))
        #expect(harness.state == .idle)
        #expect(harness.snapshot.isAlive)
        #expect(harness.snapshot.endedAt == nil)
    }

    @Test("a logged exit survives a later liveness probe")
    func loggedExitIsNotUndoneByLiveness() {
        var harness = ReducerHarness()
        harness.send(.sessionEnded(reason: .exited))
        harness.send(.liveness(alive: true))

        #expect(harness.state == .ended(reason: .exited))
        #expect(harness.snapshot.isAlive)
    }

    @Test("ended is sticky against ordinary events, but still counts them")
    func endedIsSticky() {
        var harness = ReducerHarness()
        harness.send(.sessionEnded(reason: .killed))
        harness.send([
            .userPrompt(preview: "late line"),
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "true"),
            .usage(model: "claude-opus-5", inputTokens: 10, outputTokens: 2, cachedTokens: 0),
        ])

        #expect(harness.state == .ended(reason: .killed))
        #expect(harness.snapshot.turnCount == 1)
        #expect(harness.snapshot.toolCallCount == 1)
        #expect(harness.snapshot.tokensIn == 10)
        #expect(harness.snapshot.lastEventAt == harness.clock)
    }

    @Test("an explicit restart leaves the ended state")
    func sessionStartedRevivesAnEndedSession() {
        var harness = ReducerHarness()
        harness.send(.sessionEnded(reason: .exited))
        harness.send(.sessionStarted(identity: makeIdentity()))

        #expect(harness.state == .idle)
        #expect(harness.snapshot.isAlive)
        #expect(harness.snapshot.endedAt == nil)
    }

    // MARK: - Staleness

    @Test("a working session goes stale after the threshold, and only then")
    func stalenessThreshold() {
        var harness = ReducerHarness(staleAfter: 90)
        harness.send([
            .userPrompt(preview: "run the suite"),
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
        ])
        let last = harness.clock

        #expect(harness.reducer.refreshStaleness(harness.snapshot, now: last).isStale == false)
        #expect(harness.reducer.refreshStaleness(harness.snapshot, now: last.addingTimeInterval(89)).isStale == false)
        #expect(harness.reducer.refreshStaleness(harness.snapshot, now: last.addingTimeInterval(90)).isStale == false)
        #expect(harness.reducer.refreshStaleness(harness.snapshot, now: last.addingTimeInterval(91)).isStale)
    }

    @Test("an event clears staleness again")
    func stalenessClearedByAnEvent() {
        var harness = ReducerHarness(staleAfter: 30)
        harness.send([
            .userPrompt(preview: "run the suite"),
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
        ])
        harness.snapshot = harness.reducer.refreshStaleness(harness.snapshot, now: harness.clock.addingTimeInterval(120))
        #expect(harness.snapshot.isStale)

        harness.send(.assistantText(preview: "still going"), advance: 200)
        #expect(harness.snapshot.isStale == false)
    }

    @Test("waiting, delegating, idle, and ended sessions are never stale", arguments: [
        SessionState.idle,
        .waitingPermission(tool: "Bash"),
        .delegating(children: 2),
        .ended(reason: .exited),
    ])
    func statesThatNeverGoStale(_ state: SessionState) {
        let reducer = SessionStateReducer(staleAfter: 1)
        var snapshot = SessionStateReducer.initialSnapshot(identity: makeIdentity())
        snapshot.state = state
        snapshot.lastEventAt = epoch
        #expect(reducer.refreshStaleness(snapshot, now: epoch.addingTimeInterval(10_000)).isStale == false)
    }

    @Test("a dead session is never stale")
    func deadSessionsAreNotStale() {
        let reducer = SessionStateReducer(staleAfter: 1)
        var snapshot = SessionStateReducer.initialSnapshot(identity: makeIdentity())
        snapshot.state = .thinking
        snapshot.isAlive = false
        snapshot.lastEventAt = epoch
        #expect(reducer.refreshStaleness(snapshot, now: epoch.addingTimeInterval(10_000)).isStale == false)
    }

    @Test("a session that has said nothing at all is not stale")
    func neverHeardFromIsNotStale() {
        let reducer = SessionStateReducer(staleAfter: 1)
        var snapshot = SessionStateReducer.initialSnapshot(identity: makeIdentity())
        snapshot.state = .thinking
        #expect(reducer.refreshStaleness(snapshot, now: epoch.addingTimeInterval(10_000)).isStale == false)
    }

    // MARK: - Counters

    @Test("usage deltas accumulate")
    func tokenAccumulation() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "hello"),
            .usage(model: "claude-opus-5", inputTokens: 1_200, outputTokens: 340, cachedTokens: 8_000),
            .usage(model: "claude-opus-5", inputTokens: 80, outputTokens: 12, cachedTokens: 8_000),
            .turnEnded(reason: .complete),
        ])

        #expect(harness.snapshot.tokensIn == 1_280)
        #expect(harness.snapshot.tokensOut == 352)
        #expect(harness.snapshot.tokensCached == 16_000)
        // The model on a usage record is accounting, not identity.
        #expect(harness.snapshot.identity.model == nil)
    }

    @Test("out-of-order timestamps never move lastEventAt backwards")
    func heartbeatIsMonotonic() {
        var harness = ReducerHarness()
        harness.send(.userPrompt(preview: "hello"))
        let latest = harness.clock

        harness.send(.note("a line flushed with an older timestamp"), advance: -60)
        #expect(harness.snapshot.lastEventAt == latest)
        #expect(harness.snapshot.pending.lastEventAt == latest)
    }

    @Test("the most recent open tool call wins ties deterministically")
    func mostRecentOpenToolCallIsDeterministic() {
        let first = PendingToolCall(id: "aaa", name: "Read", kind: .fileRead, target: nil, startedAt: epoch)
        let second = PendingToolCall(id: "zzz", name: "Grep", kind: .search, target: nil, startedAt: epoch)
        let pending = PendingSet(openToolCalls: ["aaa": first, "zzz": second])
        #expect(pending.mostRecentOpenToolCall == second)
    }
}

@Suite("SessionState")
struct SessionStateTests {
    @Test("labels")
    func labels() {
        #expect(SessionState.idle.label == "Idle")
        #expect(SessionState.thinking.label == "Thinking")
        #expect(SessionState.toolCalling(name: "Bash").label == "Tool: Bash")
        #expect(SessionState.writingFile(path: "/Users/example/a.swift").label == "Writing file")
        #expect(SessionState.delegating(children: 2).label == "Delegating (2)")
        #expect(SessionState.waitingPermission(tool: "Bash").label == "Waiting for permission")
        #expect(SessionState.ended(reason: .exited).label == "Ended")
    }

    @Test("only idle and ended are inactive")
    func isActive() {
        #expect(SessionState.idle.isActive == false)
        #expect(SessionState.ended(reason: .unknown).isActive == false)
        #expect(SessionState.thinking.isActive)
        #expect(SessionState.toolCalling(name: "Bash").isActive)
        #expect(SessionState.writingFile(path: nil).isActive)
        #expect(SessionState.delegating(children: 1).isActive)
        #expect(SessionState.waitingPermission(tool: nil).isActive)
    }

    @Test("board ordering puts blocked sessions first and finished ones last")
    func sortRank() {
        let ordered: [SessionState] = [
            .waitingPermission(tool: "Bash"),
            .delegating(children: 1),
            .writingFile(path: nil),
            .toolCalling(name: "Bash"),
            .thinking,
            .idle,
            .ended(reason: .exited),
        ]
        #expect(ordered.map(\.sortRank) == [0, 1, 2, 3, 4, 5, 6])
        #expect(ordered.shuffled().sorted { $0.sortRank < $1.sortRank } == ordered)
    }

    @Test("isEnded")
    func isEnded() {
        #expect(SessionState.ended(reason: .processGone).isEnded)
        #expect(SessionState.idle.isEnded == false)
    }
}
