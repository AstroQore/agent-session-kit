import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

/// What the two per-session repetitions cost, counted rather than timed.
///
/// Both are the same shape of mistake as the discovery sweep before it: a
/// question about the *machine*, or a write covering every source, paid once
/// per session on a board with hundreds of them.
@Suite("Pipeline cost", .serialized)
struct PipelineCostTests {
    @Test("a board of two hundred sources writes one cursor when one moves")
    func oneCursorPerMovedSource() async throws {
        let tree = TemporaryTree()
        let sources = 200
        for index in 0..<sources {
            tree.write(fixtureLine("history"), to: String(format: "session-%03d.jsonl", index))
        }
        let store = IncrementalCursorStore()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            configuration: IngestConfiguration(
                rediscoverEvery: .seconds(30),
                cursorSaveEvery: .milliseconds(200),
                watcherLatency: 0.05,
                watcherFlags: [.fileEvents, .noDefer, .watchRoot])
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(10)) {
            await coordinator.trackedPaths().count == sources
        })
        // The cold-start seeds move every cursor once; that is the one save
        // that legitimately covers everything.
        #expect(await waitUntil(timeout: .seconds(10)) {
            await store.writtenKeys.count == sources
        })
        let settled = await store.writes.count

        try await Task.sleep(for: .milliseconds(400))
        tree.append(fixtureLine("one-line"), to: "session-042.jsonl")

        #expect(await waitUntil(timeout: .seconds(5)) { await store.writes.count > settled })
        try await Task.sleep(for: .milliseconds(400))
        let after = Array(await store.writes.dropFirst(settled))
        let allCount = await store.lastAllCount

        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.count == 1 })
        #expect(after.allSatisfy { $0 == [tree.file("session-042.jsonl").path] })
        print(
            """
            [cursors] \(sources) sources tracked, \(allCount) in the snapshot
              one source gained a line: \(after.count) save(s), \
            \(after.map(\.count).max() ?? 0) cursor written per save \
            (was \(allCount) — every source, every two seconds)
            """)
        await coordinator.stop()
    }

    @Test("six hundred questions about a handful of pids cost one read each")
    func environmentsAreReadOncePerPid() {
        let table = ProcessTable(maxAge: 60, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        // The pids a liveness pass actually asks about: a harness's worker
        // processes, a handful of them, asked about once per session. Our own
        // is excluded — it is answered from `ProcessInfo` rather than from the
        // kernel, so it is neither read nor remembered.
        let pids = Array(table.processes().map(\.pid).filter { $0 != getpid() }.prefix(4))
        #expect(!pids.isEmpty)

        let sessions = 600
        for _ in 0..<sessions {
            for pid in pids { _ = table.environment(pid: pid) }
        }

        let reads = table.environmentReadCount()
        #expect(reads <= pids.count)
        #expect(table.rememberedEnvironmentCount() == pids.count)
        print(
            """
            [liveness] \(sessions) sessions × \(pids.count) pids \
            = \(sessions * pids.count) environment questions
              KERN_PROCARGS2 reads: \(reads) (was one per question)
            """)

        // A new window is a new set of answers, and costs the pids again.
        table.refresh()
        for pid in pids { _ = table.environment(pid: pid) }
        #expect(table.environmentReadCount() <= 2 * pids.count)
    }
}
