import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("IngestCoordinator", .serialized)
struct IngestCoordinatorTests {
    /// The shipped defaults, minus two things a test cannot live with:
    /// `ignoreSelf` would suppress the fixture writes this process makes,
    /// and a fifteen-second rediscovery would outlast the test.
    private func configuration(
        rediscoverEvery: Duration = .seconds(1),
        dropAfter: Duration = .seconds(600),
        cursorSaveEvery: Duration = .seconds(1)
    ) -> IngestConfiguration {
        IngestConfiguration(
            rediscoverEvery: rediscoverEvery,
            rediscoverThrottle: .milliseconds(200),
            dropAfter: dropAfter,
            cursorSaveEvery: cursorSaveEvery,
            watcherLatency: 0.05,
            watcherFlags: [.fileEvents, .noDefer, .watchRoot]
        )
    }

    @Test("registering a source hands the host its seed identity first")
    func seedIdentityArrivesFirst() async throws {
        let tree = TemporaryTree(#function)
        tree.write(fixtureLine("history"), to: "alpha.jsonl")
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            cursorStore: nil,
            configuration: configuration()
        )

        let (events, _) = await coordinator.start()
        let arrived = await collect(events, upTo: 2, timeout: .seconds(3))
        await coordinator.stop()

        let first = try #require(arrived.first)
        guard case .sessionStarted(let identity) = first.kind else {
            Issue.record("expected sessionStarted first, got \(first.kind)")
            return
        }
        #expect(identity.key.sessionID == "alpha.jsonl")
        #expect(identity.cwd == "/Users/example/fake-project")
        #expect(identity.title == "seed:alpha.jsonl")
        // Stamped with the file's birth, not the moment Auspex looked.
        #expect(first.timestamp <= first.observedAt)
        #expect(arrived.dropFirst().map(noteText) == ["history"])
    }

    @Test("lines appended after start arrive on the event stream")
    func appendedLinesArrive() async throws {
        let tree = TemporaryTree()
        tree.write("", to: "alpha.jsonl")
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            cursorStore: nil,
            configuration: configuration()
        )

        let (events, _) = await coordinator.start()
        // Let discovery run and the watch arm before writing anything.
        #expect(await waitUntil(timeout: .seconds(3)) {
            await coordinator.trackedPaths().count == 1
        })
        try await Task.sleep(for: .milliseconds(200))

        tree.append(fixtureLine("one") + fixtureLine("two") + fixtureLine("three"), to: "alpha.jsonl")

        let arrived = await collectTailed(events, upTo: 3, timeout: .seconds(3))
        #expect(arrived.map(noteText) == ["one", "two", "three"])
        #expect(arrived.allSatisfy { $0.session.sessionID == "alpha.jsonl" })
        #expect(arrived.allSatisfy { $0.raw?.path == tree.file("alpha.jsonl").path })
        await coordinator.stop()
    }

    @Test("discovery announces its sources on the notice stream")
    func discoveryNotices() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("seeded"), to: "beta.jsonl")
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: configuration()
        )

        let (_, notices) = await coordinator.start()
        let arrived = await collect(notices, upTo: 1, timeout: .seconds(3))
        #expect(
            arrived.first
                == .sourceDiscovered(
                    SessionKey(harness: .claudeCode, sessionID: "beta.jsonl"),
                    path: tree.file("beta.jsonl").path))
        await coordinator.stop()
    }

    @Test("cursors are persisted on stop and resumed on the next run")
    func cursorsSurviveARestart() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("history-one") + fixtureLine("history-two"), to: "gamma.jsonl")
        let path = tree.file("gamma.jsonl").path
        let store = InMemoryCursorStore()
        let adapter = FakeSourceAdapter(root: tree.url)

        // First run: cold start seeds from the tail, so the two existing
        // lines are replayed once.
        let first = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )
        let (firstEvents, _) = await first.start()
        let seeded = await collectTailed(firstEvents, upTo: 2, timeout: .seconds(3))
        #expect(seeded.map(noteText) == ["history-one", "history-two"])
        await first.stop()

        #expect(await store.saveCount >= 1)
        let saved = await store.cursors
        let cursor = try #require(saved[path])
        guard case let .byteOffset(_, offset) = cursor else {
            Issue.record("expected a byte-offset cursor, got \(cursor)")
            return
        }
        #expect(offset == FileStamp.read(path: path)?.size)

        // Second run: the saved cursor means the same two lines are not
        // replayed, and only what came after them is.
        let second = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            cursorStore: store,
            configuration: configuration()
        )
        let (secondEvents, _) = await second.start()
        #expect(await waitUntil(timeout: .seconds(3)) {
            await second.trackedPaths().count == 1
        })
        try await Task.sleep(for: .milliseconds(300))
        tree.append(fixtureLine("brand-new"), to: "gamma.jsonl")

        let resumed = await collectTailed(secondEvents, upTo: 1, timeout: .seconds(3))
        #expect(resumed.map(noteText) == ["brand-new"])
        await second.stop()
    }

    @Test("a session file created after start is picked up by rediscovery")
    func lateSourceIsDiscovered() async throws {
        let tree = TemporaryTree()
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: configuration()
        )

        let (events, _) = await coordinator.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await coordinator.trackedPaths().isEmpty)

        tree.write(fixtureLine("appeared"), to: "delta.jsonl")
        let arrived = await collectTailed(events, upTo: 1, timeout: .seconds(5))
        #expect(arrived.map(noteText) == ["appeared"])
        #expect(await coordinator.trackedPaths() == [tree.file("delta.jsonl").path])
        await coordinator.stop()
    }

    @Test("a source that stops being discovered is dropped, keeping its cursor")
    func vanishedSourceIsDropped() async throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("only-line"), to: "epsilon.jsonl")
        let path = tree.file("epsilon.jsonl").path
        let store = InMemoryCursorStore()
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            cursorStore: store,
            configuration: configuration(
                rediscoverEvery: .milliseconds(300), dropAfter: .milliseconds(500))
        )

        let (_, notices) = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) {
            await coordinator.trackedPaths().count == 1
        })

        try FileManager.default.removeItem(atPath: path)
        let dropped = await collect(notices, upTo: 2, timeout: .seconds(5))
        #expect(
            dropped.contains(
                .sourceDropped(
                    SessionKey(harness: .claudeCode, sessionID: "epsilon.jsonl"), path: path)))
        // The cursor outlives the tailer, so a session that comes back
        // resumes rather than replaying.
        #expect(await coordinator.snapshotCursors()[path] != nil)
        await coordinator.stop()
    }

    @Test("starting twice does not start a second pipeline")
    func startIsIdempotent() async throws {
        let tree = TemporaryTree()
        tree.write("", to: "zeta.jsonl")
        let adapter = FakeSourceAdapter(root: tree.url)
        let coordinator = IngestCoordinator(
            adapters: [adapter],
            home: tree.path,
            configuration: configuration(rediscoverEvery: .seconds(30)))

        let (events, _) = await coordinator.start()
        _ = await coordinator.start()
        #expect(await waitUntil(timeout: .seconds(3)) {
            await coordinator.trackedPaths().count == 1
        })
        try await Task.sleep(for: .milliseconds(300))
        tree.append(fixtureLine("once"), to: "zeta.jsonl")

        // A second pipeline would mean a second tailer over the same file and
        // the line arriving twice.
        let arrived = await collectTailed(events, upTo: 2, timeout: .seconds(2))
        #expect(arrived.map(noteText) == ["once"])
        await coordinator.stop()
    }

    @Test("stopping without a cursor store is quiet")
    func stopWithoutStore() async throws {
        let tree = TemporaryTree()
        let coordinator = IngestCoordinator(
            adapters: [FakeSourceAdapter(root: tree.url)],
            home: tree.path,
            configuration: configuration())
        _ = await coordinator.start()
        await coordinator.stop()
        #expect(await coordinator.trackedPaths().isEmpty)
    }
}

@Suite("Cursor stores")
struct SourceCursorStoreTests {
    @Test("the in-memory store round-trips and counts its saves")
    func inMemory() async throws {
        let store = InMemoryCursorStore(["/a": .rowID(3)])
        #expect(await store.load() == ["/a": .rowID(3)])
        try await store.save(["/b": .byteOffset(inode: 7, offset: 21)])
        #expect(await store.load() == ["/b": .byteOffset(inode: 7, offset: 21)])
        #expect(await store.saveCount == 1)
    }

    @Test("the JSON file store round-trips through disk")
    func jsonFile() async throws {
        let tree = TemporaryTree()
        let store = JSONFileCursorStore(url: tree.file("nested/cursors.json"))
        #expect(try store.load().isEmpty)

        let cursors: [String: SourceCursor] = [
            "/a/session.jsonl": .byteOffset(inode: 42, offset: 1024),
            "/b/store.db": .rowID(9),
            "/c/blob": .blobHead("deadbeef"),
        ]
        try store.save(cursors)
        #expect(try store.load() == cursors)

        // Created 0600: the file names paths under someone's home.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("an unreadable cursor file starts cold instead of failing")
    func corruptFile() async throws {
        let tree = TemporaryTree()
        tree.write("this is not json", to: "cursors.json")
        let store = JSONFileCursorStore(url: tree.file("cursors.json"))
        #expect(try store.load().isEmpty)
    }
}

@Suite("SQLiteChangeWatcher")
struct SQLiteChangeWatcherTests {
    @Test("the database and its WAL/SHM siblings are all watched")
    func watchedPaths() {
        let watcher = SQLiteChangeWatcher(databasePath: "/tmp/store.db")
        #expect(watcher.watchedPaths == ["/tmp/store.db", "/tmp/store.db-wal", "/tmp/store.db-shm"])
        #expect(watcher.owns(path: "/tmp/store.db-wal"))
        #expect(!watcher.owns(path: "/tmp/other.db"))
    }

    @Test("a WAL write is reported even though the database did not move")
    func walWriteIsAChange() async throws {
        let tree = TemporaryTree()
        tree.write("sqlite", to: "store.db")
        let watcher = SQLiteChangeWatcher(databasePath: tree.file("store.db").path)
        watcher.primeWithCurrentState()
        #expect(watcher.check().isEmpty)

        tree.write("wal bytes", to: "store.db-wal")
        let changes = watcher.check()
        #expect(changes.map(\.path) == [tree.file("store.db-wal").path])
        #expect(watcher.check().isEmpty)
    }

    @Test("a checkpoint that removes the WAL counts as a change")
    func checkpointIsAChange() throws {
        let tree = TemporaryTree()
        tree.write("sqlite", to: "store.db")
        tree.write("wal bytes", to: "store.db-wal")
        let watcher = SQLiteChangeWatcher(databasePath: tree.file("store.db").path)
        watcher.primeWithCurrentState()

        try FileManager.default.removeItem(at: tree.file("store.db-wal"))
        #expect(watcher.check().map(\.path) == [tree.file("store.db-wal").path])
    }

    @Test("store files are recognised by shape, and nothing else is")
    func storeFileShapes() {
        #expect(SQLiteChangeWatcher.databasePath(forStoreFile: "/x/store.db") == "/x/store.db")
        #expect(SQLiteChangeWatcher.databasePath(forStoreFile: "/x/store.db-wal") == "/x/store.db")
        #expect(SQLiteChangeWatcher.databasePath(forStoreFile: "/x/store.db-shm") == "/x/store.db")
        #expect(SQLiteChangeWatcher.databasePath(forStoreFile: "/x/store.sqlite3") == "/x/store.sqlite3")
        #expect(SQLiteChangeWatcher.databasePath(forStoreFile: "/x/session.jsonl") == nil)
        #expect(!SQLiteChangeWatcher.isStoreFile("/x/session.jsonl"))
    }

    @Test("ticks reach the change stream")
    func changeStream() async throws {
        let tree = TemporaryTree()
        tree.write("sqlite", to: "store.db")
        let watcher = SQLiteChangeWatcher(databasePath: tree.file("store.db").path, pollInterval: 0.2)
        watcher.primeWithCurrentState()
        watcher.start()
        defer { watcher.stop() }

        tree.write("wal bytes", to: "store.db-wal")
        let batches = await collect(watcher.changes, upTo: 1, timeout: .seconds(3))
        #expect(batches.first?.map(\.path) == [tree.file("store.db-wal").path])
    }
}
