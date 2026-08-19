import AgentSessionKit
import Foundation
@testable import AgentSessionLive

// MARK: - Temporary trees

/// A temporary directory that removes itself.
///
/// Every test in this file writes its own fixture tree and tears it down;
/// nothing reads the real home directory. The name carries the test's own
/// name so a leftover after a crash says which test leaked it.
final class TemporaryTree: @unchecked Sendable {
    // `@unchecked` because the only mutable state is the directory on disk,
    // and each instance is owned by exactly one test.
    let url: URL

    init(_ label: String = #function) {
        let sanitised = label.replacingOccurrences(of: "()", with: "")
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-session-live-\(sanitised)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    @discardableResult
    func write(_ contents: String, to name: String) -> URL {
        let target = file(name)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: target)
        return target
    }

    func append(_ contents: String, to name: String) {
        let target = file(name)
        guard let handle = FileHandle(forWritingAtPath: target.path) else {
            write(contents, to: name)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(contents.utf8))
    }

    func inode(of name: String) -> UInt64? {
        FileStamp.read(path: file(name).path)?.inode
    }
}

// MARK: - Async waiting

/// Collects up to `count` values from `stream`, giving up after `timeout`.
///
/// Returns whatever arrived, so a test can assert on a partial result rather
/// than only on "did it time out". The polling loop is deliberately dumb: a
/// `withTaskGroup` race loses the values the collector had already gathered
/// when the timeout wins, which is exactly the diagnostic a flaky test needs.
func collect<T: Sendable>(
    _ stream: AsyncStream<T>,
    upTo count: Int,
    timeout: Duration = .seconds(5)
) async -> [T] {
    let collector = ValueBox<T>()
    let task = Task {
        for await value in stream {
            let total = await collector.append(value)
            if total >= count { break }
        }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await collector.count >= count { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    return await collector.values
}

/// Like ``collect(_:upTo:timeout:)`` but ignores the `sessionStarted` a
/// coordinator emits when it registers a source, so tests about tailing can
/// count only the events the tail produced.
func collectTailed(
    _ stream: AsyncStream<AgentEvent>,
    upTo count: Int,
    timeout: Duration = .seconds(5)
) async -> [AgentEvent] {
    let collector = ValueBox<AgentEvent>()
    let task = Task {
        for await value in stream {
            if case .sessionStarted = value.kind { continue }
            let total = await collector.append(value)
            if total >= count { break }
        }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await collector.count >= count { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    return await collector.values
}

/// Polls `condition` until it holds or `timeout` elapses.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(5),
    every step: Duration = .milliseconds(20),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: step)
    }
    return await condition()
}

actor ValueBox<T: Sendable> {
    private(set) var values: [T] = []

    var count: Int { values.count }

    @discardableResult
    func append(_ value: T) -> Int {
        values.append(value)
        return values.count
    }
}

// MARK: - A decoder for synthetic JSONL

/// The one-field record every JSONL fixture in this suite is made of.
struct FixtureLine: Codable, Sendable {
    let text: String
}

/// Builds a ``JSONLTailer`` decoder over ``FixtureLine``.
///
/// Anything that is not a `FixtureLine` yields no events — which is how a
/// tailer is meant to treat garbage, and what the garbage-line test asserts.
func fixtureDecoder(
    key: SessionKey,
    observedAt: Date? = nil
) -> @Sendable (Data, JSONLLineRef) -> [AgentEvent] {
    { data, _ in
        guard let line = try? JSONDecoder().decode(FixtureLine.self, from: data) else { return [] }
        return [
            AgentEvent(
                session: key,
                timestamp: epoch,
                observedAt: observedAt ?? epoch,
                kind: .note(line.text)
            )
        ]
    }
}

/// One JSONL line of the shape ``FixtureLine`` expects, newline included.
func fixtureLine(_ text: String) -> String {
    #"{"text":"\#(text)"}"# + "\n"
}

/// The note text carried by an event, or `nil` for any other kind.
func noteText(_ event: AgentEvent) -> String? {
    guard case let .note(text) = event.kind else { return nil }
    return text
}

// MARK: - A source adapter over a synthetic tree

/// A ``SourceAdapter`` over one directory of JSONL files.
///
/// Discovers every `*.jsonl` directly inside `root`, one session each, keyed
/// by file name. Enough to drive the coordinator end to end without any
/// harness's real format being involved.
struct FakeSourceAdapter: SourceAdapter {
    let harness: Harness
    let root: URL
    /// Bumped by ``discover(home:activeSince:)`` so a test can tell whether
    /// rediscovery actually ran.
    let discoveries: ValueBox<Date>

    init(harness: Harness = .claudeCode, root: URL, discoveries: ValueBox<Date> = ValueBox()) {
        self.harness = harness
        self.root = root
        self.discoveries = discoveries
    }

    func watchRoots(home: String) -> [URL] { [root] }

    func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        await discoveries.append(Date())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { name in
            let path = root.appendingPathComponent(name).path
            let key = SessionKey(harness: harness, sessionID: name)
            return SessionSource(
                key: key,
                primaryPath: path,
                seedIdentity: SessionIdentity(
                    key: key,
                    sourcePath: path,
                    cwd: "/Users/example/fake-project",
                    title: "seed:" + name
                )
            )
        }
    }

    func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        JSONLTailer(source: source, cursor: cursor, decode: fixtureDecoder(key: source.key))
    }

    func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        .unknown("fixture adapter has no process to probe")
    }
}

/// A process table over a fixed array, for driving liveness branches.
struct FakeProcessTable: ProcessTableReading {
    let records: [ProcessRecord]
    var environments: [pid_t: [String: String]] = [:]

    func processes() -> [ProcessRecord] { records }

    func environment(pid: pid_t) -> [String: String]? {
        environments[pid].map(ArgvSanitizer.sanitizeEnvironment)
    }
}

/// An adapter whose liveness answer a test dictates.
struct ScriptedLivenessAdapter: SourceAdapter {
    let harness: Harness
    let verdict: LivenessHint
    /// Harnesses this adapter answers for besides its own, so the resolver's
    /// indexing by `handledHarnesses` can be driven directly.
    var alsoHandles: [Harness] = []

    var handledHarnesses: [Harness] { [harness] + alsoHandles }

    func watchRoots(home: String) -> [URL] { [] }
    func discover(home: String, activeSince: Date) async throws -> [SessionSource] { [] }

    func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        JSONLTailer(source: source, cursor: cursor) { _, _ in [] }
    }

    func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        verdict
    }
}
