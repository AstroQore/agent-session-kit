import AgentSessionKit
import Foundation
@testable import AgentSessionLive

/// A fixed instant every test builds its timeline from, so nothing here
/// depends on when the suite runs. Whole seconds since the reference date,
/// which is also what makes the `Codable` round-trips exact.
let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

let parentKey = SessionKey(harness: .claudeCode, sessionID: "11111111-1111-1111-1111-111111111111")
let childKey = SessionKey(harness: .codex, sessionID: "22222222-2222-2222-2222-222222222222")
let otherChildKey = SessionKey(harness: .codex, sessionID: "33333333-3333-3333-3333-333333333333")

func makeIdentity(
    key: SessionKey = parentKey,
    sourcePath: String = "/Users/example/.claude/projects/demo/session.jsonl"
) -> SessionIdentity {
    SessionIdentity(key: key, sourcePath: sourcePath, cwd: "/Users/example/code/demo")
}

/// Drives a reducer over a scripted event sequence on a synthetic clock.
///
/// One second passes between events unless a step says otherwise, which is
/// short enough that nothing goes stale by accident and long enough that
/// ordering is unambiguous.
struct ReducerHarness {
    var reducer: SessionStateReducer
    var snapshot: SessionSnapshot
    var clock: Date
    private(set) var sequence: Int64 = 0

    init(staleAfter: TimeInterval = 90, identity: SessionIdentity = makeIdentity(), start: Date = epoch) {
        self.reducer = SessionStateReducer(staleAfter: staleAfter)
        self.snapshot = SessionStateReducer.initialSnapshot(identity: identity)
        self.clock = start
    }

    @discardableResult
    mutating func send(_ kind: AgentEventKind, advance: TimeInterval = 1) -> SessionSnapshot {
        clock = clock.addingTimeInterval(advance)
        sequence += 1
        let event = AgentEvent(
            session: snapshot.identity.key,
            timestamp: clock,
            sequence: sequence,
            kind: kind
        )
        snapshot = reducer.reduce(snapshot, event: event)
        return snapshot
    }

    mutating func send(_ kinds: [AgentEventKind]) {
        for kind in kinds { send(kind) }
    }

    var state: SessionState { snapshot.state }
}

/// One scripted scenario for the table-driven reducer tests.
struct ReducerScenario: Sendable {
    let name: String
    let script: [AgentEventKind]
    let expectedState: SessionState
    let expectedTurns: Int
    let expectedToolCalls: Int
    let expectedAlive: Bool

    init(
        _ name: String,
        script: [AgentEventKind],
        expectedState: SessionState,
        expectedTurns: Int = 1,
        expectedToolCalls: Int = 0,
        expectedAlive: Bool = true
    ) {
        self.name = name
        self.script = script
        self.expectedState = expectedState
        self.expectedTurns = expectedTurns
        self.expectedToolCalls = expectedToolCalls
        self.expectedAlive = expectedAlive
    }
}

extension ReducerScenario: CustomStringConvertible {
    var description: String { name }
}
