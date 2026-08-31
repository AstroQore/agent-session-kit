import Foundation
import Testing
@testable import AgentSessionLive

/// FSEvents is a system service, so these are the only tests in the suite
/// that wait on wall-clock time. Every wait is bounded and every assertion is
/// on "did the path arrive", never on how long it took: a loaded machine can
/// take a second to deliver what it usually delivers in fifty milliseconds.
///
/// Most of them drop ``FSEventsWatcher/CreateFlags/ignoreSelf`` from the
/// flags. That is not a workaround for a bug: `IgnoreSelf` asks the kernel to
/// suppress events caused by *this* process, and a test that writes its own
/// fixtures is that process. ``defaultFlagsSeeAnotherProcess`` covers the
/// shipped default by having a subprocess do the writing.
@Suite("FSEventsWatcher", .serialized)
struct FSEventsWatcherTests {
    /// Generous on purpose. The point of the timeout is to fail rather than
    /// hang, not to measure latency.
    private let patience = Duration.seconds(6)

    /// The shipped default minus `ignoreSelf`; see the suite's discussion.
    private let observableFlags: FSEventsWatcher.CreateFlags = [.fileEvents, .noDefer, .watchRoot]

    private func batch(
        _ watcher: FSEventsWatcher,
        containing path: String
    ) async -> FSEventBatch? {
        let found = ValueBox<FSEventBatch>()
        let task = Task {
            for await batch in watcher.batches where batch.paths.contains(path) {
                await found.append(batch)
                break
            }
        }
        _ = await waitUntil(timeout: patience) { await found.count > 0 }
        task.cancel()
        return await found.values.first
    }

    @Test("a file created under a watched root arrives in a batch")
    func createdFileArrives() async throws {
        let tree = TemporaryTree()
        let watcher = FSEventsWatcher(paths: [tree.path], latency: 0.05, flags: observableFlags)
        watcher.start()
        defer { watcher.stop() }

        // Give the stream a moment to arm; events from before it started are
        // not delivered.
        try await Task.sleep(for: .milliseconds(300))
        let target = tree.file("appeared.jsonl")
        tree.write("hello\n", to: "appeared.jsonl")

        let batch = await batch(watcher, containing: target.path)
        let delivered = try #require(batch, "FSEvents delivered nothing within \(patience)")
        #expect(delivered.paths.contains(target.path))
        #expect(delivered.flagsByPath[target.path] != nil)
        #expect(delivered.eventIDs[target.path] != nil)
    }

    @Test("modifying an existing file arrives in a batch")
    func modifiedFileArrives() async throws {
        let tree = TemporaryTree()
        tree.write("first\n", to: "session.jsonl")
        let watcher = FSEventsWatcher(paths: [tree.path], latency: 0.05, flags: observableFlags)
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(300))
        tree.append("second\n", to: "session.jsonl")

        let target = tree.file("session.jsonl").path
        _ = try #require(
            await batch(watcher, containing: target),
            "FSEvents delivered nothing within \(patience)")
    }

    @Test("paths outside the declared roots are filtered out")
    func unrelatedPathsFiltered() async throws {
        let outer = TemporaryTree()
        let watched = outer.url.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)

        let watcher = FSEventsWatcher(paths: [watched.path], latency: 0.05, flags: observableFlags)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // A sibling of the watched directory: inside the ancestor FSEvents is
        // actually subscribed to, outside what the caller asked about.
        outer.write("noise\n", to: "sibling.jsonl")
        try Data("real\n".utf8).write(to: watched.appendingPathComponent("session.jsonl"))

        let target = watched.appendingPathComponent("session.jsonl").path
        let delivered = try #require(
            await batch(watcher, containing: target),
            "FSEvents delivered nothing within \(patience)")
        #expect(!delivered.paths.contains(outer.file("sibling.jsonl").path))
    }

    @Test("a root that does not exist yet is watched through its ancestor")
    func lateRootIsPickedUp() async throws {
        let tree = TemporaryTree()
        let late = tree.url.appendingPathComponent("not/there/yet")

        let watcher = FSEventsWatcher(
            paths: [late.path], latency: 0.05, flags: observableFlags, rearmInterval: 0.2)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // Before the root exists, FSEvents is subscribed to the nearest
        // existing ancestor rather than to nothing.
        let earlyWatch = watcher.currentWatchPaths()
        #expect(earlyWatch.count == 1)
        #expect(earlyWatch.first?.hasSuffix(tree.url.lastPathComponent) == true)

        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)

        // Directory creation can itself trigger the rearm. Wait for that
        // narrower stream before writing the file: writing in the teardown /
        // startup gap makes the assertion depend on whether the runner's
        // FSEvents callback or the test task wins the same scheduler turn.
        #expect(await waitUntil(timeout: .seconds(3)) {
            watcher.currentWatchPaths().first?.hasSuffix("not/there/yet") == true
        })

        let target = late.appendingPathComponent("session.jsonl")
        try Data("late\n".utf8).write(to: target)

        _ = try #require(
            await batch(watcher, containing: target.path),
            "FSEvents delivered nothing for a late root within \(patience)")

        #expect(watcher.currentWatchPaths().first?.hasSuffix("not/there/yet") == true)
    }

    @Test("the shipped default flags see another process's writes")
    func defaultFlagsSeeAnotherProcess() async throws {
        let tree = TemporaryTree()
        let watcher = FSEventsWatcher(paths: [tree.path], latency: 0.05)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // `ignoreSelf` suppresses only *our* writes, so the write has to come
        // from somewhere else for the default configuration to be observable.
        let target = tree.file("from-elsewhere.jsonl")
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "printf 'x\\n' > \"$0\"", target.path]
        try writer.run()
        writer.waitUntilExit()
        try #require(writer.terminationStatus == 0)

        _ = try #require(
            await batch(watcher, containing: target.path),
            "FSEvents delivered nothing within \(patience)")
    }

    @Test("stopping finishes the stream")
    func stopFinishesStream() async throws {
        let tree = TemporaryTree()
        let watcher = FSEventsWatcher(paths: [tree.path], latency: 0.05, flags: observableFlags)
        watcher.start()
        try await Task.sleep(for: .milliseconds(200))
        watcher.stop()

        let finished = ValueBox<Bool>()
        let task = Task {
            for await _ in watcher.batches {}
            await finished.append(true)
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await finished.count > 0 })
        task.cancel()
    }

    // MARK: - Path arithmetic, without touching FSEvents

    @Test("roots are normalised and deduplicated, order preserved")
    func normalisation() {
        #expect(
            FSEventsWatcher.normalise(["/a/b/", "/a/b", "/c///", "", "/"])
                == ["/a/b", "/c", "/"])
    }

    @Test("a covered watch path is dropped in favour of its ancestor")
    func coveringAncestorWins() {
        let roots = [
            FSEventsWatcher.ResolvedRoot(declared: "/a/b", canonical: "/a/b", watch: "/a/b"),
            FSEventsWatcher.ResolvedRoot(declared: "/a", canonical: "/a", watch: "/a"),
            FSEventsWatcher.ResolvedRoot(declared: "/z", canonical: "/z", watch: "/z"),
        ]
        #expect(FSEventsWatcher.watchPaths(of: roots) == ["/a", "/z"])
    }

    @Test("containment is string arithmetic, and a prefix is not a parent")
    func containment() {
        #expect(FSEventsWatcher.isPath("/a/b", underOrEqualTo: "/a"))
        #expect(FSEventsWatcher.isPath("/a", underOrEqualTo: "/a"))
        #expect(!FSEventsWatcher.isPath("/abc", underOrEqualTo: "/a"))
        #expect(FSEventsWatcher.isPath("/anything", underOrEqualTo: "/"))
    }

    @Test("a missing root resolves to its nearest existing ancestor")
    func nearestAncestor() {
        let tree = TemporaryTree()
        let missing = tree.url.appendingPathComponent("no/such/place").path
        #expect(FSEventsWatcher.nearestExistingDirectory(missing) == tree.path)
        #expect(FSEventsWatcher.nearestExistingDirectory(tree.path) == tree.path)
    }

    @Test("resolution canonicalises the watch path but keeps the declared one")
    func canonicalisation() throws {
        let tree = TemporaryTree()
        let resolved = try #require(FSEventsWatcher.resolve([tree.path]).first)
        #expect(resolved.declared == tree.path)
        // On macOS the temporary directory lives under a symlinked `/var`,
        // which is exactly the case that makes a naive prefix filter drop
        // every event. Canonical and declared must be allowed to differ.
        #expect(resolved.canonical == FSEventsWatcher.realPath(tree.path))
        #expect(resolved.watch == resolved.canonical)
    }
}
