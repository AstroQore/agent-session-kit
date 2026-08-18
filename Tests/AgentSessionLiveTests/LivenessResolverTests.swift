import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("LivenessResolver")
struct LivenessResolverTests {
    private let key = SessionKey(harness: .claudeCode, sessionID: "liveness-fixture")

    private func identity(pid: pid_t? = nil, procStart: Date? = nil) -> SessionIdentity {
        SessionIdentity(
            key: key,
            sourcePath: "/Users/example/.claude/projects/demo/session.jsonl",
            pid: pid,
            procStart: procStart
        )
    }

    private func table(pid: pid_t, startTime: Date) -> FakeProcessTable {
        FakeProcessTable(records: [
            ProcessRecord(pid: pid, ppid: 1, startTime: startTime, executablePath: "/bin/claude", argv: [])
        ])
    }

    @Test("a matching pid and start time is alive")
    func matchedProcess() async {
        let resolver = LivenessResolver(adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let hint = await resolver.hint(for: identity(pid: 4711, procStart: epoch))
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4711)
    }

    @Test("a pid that is not running is dead")
    func missingProcess() async {
        let resolver = LivenessResolver(adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let hint = await resolver.hint(for: identity(pid: 9999, procStart: epoch))
        #expect(hint.verdict == .dead)
    }

    @Test("a recycled pid is dead, not alive")
    func recycledPID() async {
        // Same pid, but the process running under it started an hour later.
        let resolver = LivenessResolver(
            adapters: [],
            table: table(pid: 4711, startTime: epoch.addingTimeInterval(3600)),
            home: "/Users/example")
        let hint = await resolver.hint(for: identity(pid: 4711, procStart: epoch))
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("recycled"))
    }

    @Test("start times inside the tolerance still match")
    func startTimeTolerance() async {
        let resolver = LivenessResolver(
            adapters: [],
            table: table(pid: 4711, startTime: epoch.addingTimeInterval(1.5)),
            home: "/Users/example")
        #expect(await resolver.hint(for: identity(pid: 4711, procStart: epoch)).verdict == .alive)
    }

    @Test("a session with no pid is unknown, which is not dead")
    func noPIDIsUnknown() async {
        let resolver = LivenessResolver(adapters: [], table: FakeProcessTable(records: []), home: "/Users/example")
        #expect(await resolver.hint(for: identity()).verdict == .unknown)
    }

    @Test("an adapter's answer stands where the generic check has none")
    func adapterAnswersWhenGenericCannot() async {
        let adapter = ScriptedLivenessAdapter(
            harness: .claudeCode,
            verdict: LivenessHint(verdict: .alive, pid: nil, evidence: "lock file is held"))
        let resolver = LivenessResolver(
            adapters: [adapter], table: FakeProcessTable(records: []), home: "/Users/example")
        let hint = await resolver.hint(for: identity())
        #expect(hint.verdict == .alive)
        #expect(hint.evidence == "lock file is held")
    }

    @Test("the kernel out-votes an optimistic adapter")
    func kernelBeatsAdapter() async {
        let adapter = ScriptedLivenessAdapter(
            harness: .claudeCode,
            verdict: LivenessHint(verdict: .alive, pid: 4711, evidence: "transcript was written recently"))
        let resolver = LivenessResolver(
            adapters: [adapter], table: FakeProcessTable(records: []), home: "/Users/example")
        let hint = await resolver.hint(for: identity(pid: 4711, procStart: epoch))
        #expect(hint.verdict == .dead)
    }

    @Test("an adapter for a different harness is not consulted")
    func harnessRouting() async {
        let adapter = ScriptedLivenessAdapter(
            harness: .codex,
            verdict: LivenessHint(verdict: .dead, pid: nil, evidence: "codex says no"))
        let resolver = LivenessResolver(
            adapters: [adapter], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        #expect(await resolver.hint(for: identity(pid: 4711, procStart: epoch)).verdict == .alive)
    }

    @Test("only transitions reach the stream")
    func transitionsOnly() async {
        let resolver = LivenessResolver(
            adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let alive = identity(pid: 4711, procStart: epoch)

        #expect(await resolver.tick([alive], into: continuation) == 1)
        #expect(await resolver.tick([alive], into: continuation) == 0)
        #expect(await resolver.tick([alive], into: continuation) == 0)

        // The same session, now with a pid that is not in the table.
        let gone = identity(pid: 9999, procStart: epoch)
        #expect(await resolver.tick([gone], into: continuation) == 1)
        continuation.finish()

        var kinds: [AgentEventKind] = []
        for await event in stream { kinds.append(event.kind) }
        #expect(kinds == [.liveness(alive: true), .liveness(alive: false)])
    }

    @Test("an unknown verdict does not overwrite a known one")
    func unknownIsNotATransition() async {
        let resolver = LivenessResolver(
            adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)

        #expect(await resolver.tick([identity(pid: 4711, procStart: epoch)], into: continuation) == 1)
        // No pid recorded any more — the probe learned nothing, so it says
        // nothing rather than flickering a live session.
        #expect(await resolver.tick([identity()], into: continuation) == 0)
        #expect(await resolver.tick([identity(pid: 4711, procStart: epoch)], into: continuation) == 0)
        continuation.finish()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1)
    }

    @Test("forgetting a session makes its next answer a transition again")
    func forgetting() async {
        let resolver = LivenessResolver(
            adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let alive = identity(pid: 4711, procStart: epoch)

        #expect(await resolver.tick([alive], into: continuation) == 1)
        await resolver.forget(key)
        #expect(await resolver.tick([alive], into: continuation) == 1)
        continuation.finish()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 2)
    }

    @Test("resolving a batch answers every identity once")
    func batchResolution() async {
        let other = SessionKey(harness: .claudeCode, sessionID: "second")
        let resolver = LivenessResolver(
            adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let hints = await resolver.resolve([
            identity(pid: 4711, procStart: epoch),
            SessionIdentity(key: other, sourcePath: "/tmp/other.jsonl", pid: 9999, procStart: epoch),
        ])
        #expect(hints.count == 2)
        #expect(hints[key]?.verdict == .alive)
        #expect(hints[other]?.verdict == .dead)
    }

    @Test("the run loop ticks until it is cancelled")
    func runLoopEmits() async throws {
        let resolver = LivenessResolver(
            adapters: [], table: table(pid: 4711, startTime: epoch), home: "/Users/example")
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let alive = identity(pid: 4711, procStart: epoch)

        let task = Task {
            await resolver.runLoop(every: .milliseconds(50), identities: { [alive] }, into: continuation)
        }
        let events = await collect(stream, upTo: 1, timeout: .seconds(3))
        task.cancel()
        #expect(events.map(\.kind) == [.liveness(alive: true)])
        continuation.finish()
    }
}
