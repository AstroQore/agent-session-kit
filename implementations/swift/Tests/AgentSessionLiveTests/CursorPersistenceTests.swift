import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

/// A cursor store that writes only what it is handed, and remembers every
/// call so a test can say what the coordinator asked for.
actor IncrementalCursorStore: SourceCursorStore {
    /// The stored set, as an incremental store would hold it.
    private(set) var cursors: [String: SourceCursor] = [:]
    /// One entry per ``save(changed:all:)``: the keys it was given.
    private(set) var writes: [Set<String>] = []
    /// One entry per whole-set ``save(_:)``.
    private(set) var replacements = 0
    /// How big the complete set was on the last incremental save — the number
    /// the old whole-write paid every time.
    private(set) var lastAllCount = 0
    /// How many more calls to fail before accepting one.
    var failures = 0

    struct Refused: Error {}

    init(_ initial: [String: SourceCursor] = [:]) {
        cursors = initial
    }

    func setFailures(_ count: Int) { failures = count }

    func load() -> [String: SourceCursor] { cursors }

    func save(_ cursors: [String: SourceCursor]) throws {
        if failures > 0 {
            failures -= 1
            throw Refused()
        }
        replacements += 1
        self.cursors = cursors
    }

    func save(changed: [String: SourceCursor], all: [String: SourceCursor]) throws {
        if failures > 0 {
            failures -= 1
            throw Refused()
        }
        writes.append(Set(changed.keys))
        lastAllCount = all.count
        cursors.merge(changed) { _, new in new }
    }

    /// Every key written since the store was made, in one set.
    var writtenKeys: Set<String> { writes.reduce(into: []) { $0.formUnion($1) } }
}

@Suite("Cursor persistence", .serialized)
struct CursorPersistenceTests {
    private func configuration() -> IngestConfiguration {
        IngestConfiguration(
            rediscoverEvery: .seconds(30),
            discoveryDebounce: .milliseconds(50),
            rediscoverThrottle: .milliseconds(100),
            cursorSaveEvery: .milliseconds(200),
            watcherLatency: 0.05,
            watcherFlags: [.fileEvents, .noDefer, .watchRoot]
        )
    }

    @Test("only the source that moved is written")
    func writesOnlyWhatMoved() async throws {
        let tree = TemporaryTree()
        for name in ["a.jsonl", "b.jsonl", "c.jsonl"] {
            tree.write(fixtureLine("history"), to: name)
        }
        let store = IncrementalCursorStore()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await coordinator.trackedPaths().count == 3 })
        // Let the cold-start seeds settle and be written.
        #expect(await waitUntil(timeout: .seconds(3)) { await store.writtenKeys.count == 3 })
        let settled = await store.writes.count

        // One source gains a line. Two do not.
        try await Task.sleep(for: .milliseconds(300))
        tree.append(fixtureLine("only-b"), to: "b.jsonl")

        #expect(await waitUntil(timeout: .seconds(3)) { await store.writes.count > settled })
        let after = await store.writes.dropFirst(settled)
        #expect(!after.isEmpty)
        // Every save since is about `b` alone — the whole point of the change.
        #expect(after.allSatisfy { $0 == [tree.file("b.jsonl").path] })
        await coordinator.stop()
    }

    @Test("a save with nothing dirty does not reach the store at all")
    func quietMeansNoWrite() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("history"), to: "a.jsonl")
        let store = IncrementalCursorStore()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await store.writes.count >= 1 })
        let settled = await store.writes.count

        // Five save intervals with nothing moving.
        try await Task.sleep(for: .seconds(1))
        #expect(await store.writes.count == settled)
        await coordinator.stop()
    }

    @Test("shutdown writes everything, including a source that never moved")
    func stopWritesEverything() async throws {
        let tree = TemporaryTree()
        tree.write("", to: "silent.jsonl")
        tree.write(fixtureLine("noisy"), to: "noisy.jsonl")
        let store = IncrementalCursorStore()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            // Long enough that no periodic save runs before the stop.
            configuration: IngestConfiguration(
                rediscoverEvery: .seconds(30),
                cursorSaveEvery: .seconds(30),
                watcherFlags: [.fileEvents, .noDefer, .watchRoot])
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await coordinator.trackedPaths().count == 2 })
        await coordinator.stop()

        // An empty file produces no events, so nothing ever marked it dirty —
        // and it is still in the store, so the next launch resumes it.
        let stored = await store.cursors
        #expect(stored[tree.file("silent.jsonl").path] != nil)
        #expect(stored[tree.file("noisy.jsonl").path] != nil)
    }

    @Test("a refused save is still owed, and lands on the next one")
    func failedSaveIsRetried() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("history"), to: "a.jsonl")
        let store = IncrementalCursorStore()
        await store.setFailures(10)
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )

        let (_, notices) = await coordinator.start()
        let complaints = await collect(notices, upTo: 3, timeout: .seconds(3))
        #expect(complaints.contains { notice in
            if case let .tailerError(path, _) = notice { return path == "<cursor-store>" }
            return false
        })
        #expect(await store.writes.isEmpty)

        await store.setFailures(0)
        #expect(await waitUntil(timeout: .seconds(3)) {
            await store.writtenKeys.contains(tree.file("a.jsonl").path)
        })
        await coordinator.stop()
    }

    @Test("a store that only replaces keeps being handed the whole set")
    func defaultFallsBackToAWholeWrite() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("history"), to: "a.jsonl")
        tree.write(fixtureLine("history"), to: "b.jsonl")
        // `InMemoryCursorStore` does not implement `save(changed:all:)`, so it
        // gets the protocol default — which is the whole-set write, unchanged.
        let store = InMemoryCursorStore()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )

        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) { await store.saveCount >= 1 })
        #expect(await store.cursors.count == 2)
        await coordinator.stop()
    }
}
