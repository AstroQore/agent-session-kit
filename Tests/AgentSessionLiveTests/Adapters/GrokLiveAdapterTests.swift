import AgentSessionKit
import Darwin
import Foundation
import Testing

@testable import AgentSessionLive

// MARK: - Fixtures

/// The synthetic session in `Fixtures/grok/session/`.
private let grokSession = SessionKey(
    harness: .grokBuild, sessionID: "77777777-8888-9999-aaaa-bbbbbbbbbbbb")

/// The working directory that session ran in. It has a space in it on purpose:
/// the percent-encoding round-trip is only interesting when there is something
/// besides `/` to escape.
private let grokCwd = "/Users/example/code/demo app"

/// A fixed observation clock, so nothing in the suite depends on today.
private let observed = Date(timeIntervalSince1970: 1_800_000_000)

private func fixture(_ name: String) throws -> URL {
    let url = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/grok/\(name)")
    try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
    return url
}

private func fixtureLines(_ name: String) throws -> [Data] {
    let text = try String(contentsOf: fixture(name), encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

private func mapped(
    _ file: GrokSourceFile,
    as key: SessionKey = grokSession,
    options: GrokRecordMapper.Options = .default
) throws -> [AgentEvent] {
    try fixtureLines("session/\(file.fileName)").flatMap {
        GrokRecordMapper.events(
            from: $0, file: file, session: key, now: observed, options: options)
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
    case .contextUsage: "contextUsage"
    case .quota: "quota"
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

private struct ToolStart {
    let id: String
    let name: String
    let kind: ToolKind
    let target: String?
}

private func starts(_ events: [AgentEvent]) -> [ToolStart] {
    events.compactMap {
        guard case let .toolCallStarted(id, name, kind, target) = $0.kind else { return nil }
        return ToolStart(id: id, name: name, kind: kind, target: target)
    }
}

private struct ContextReading {
    let used: Int
    let window: Int?
    let cached: Int?
    let source: ContextUsage.Source
}

private func contextReadings(_ events: [AgentEvent]) -> [ContextReading] {
    events.compactMap {
        guard case let .contextUsage(used, window, cached, source) = $0.kind else { return nil }
        return ContextReading(used: used, window: window, cached: cached, source: source)
    }
}

private func notes(_ events: [AgentEvent]) -> [String] {
    events.compactMap {
        guard case let .note(text) = $0.kind else { return nil }
        return text
    }
}

// MARK: - Mapper: events.jsonl

@Suite("GrokRecordMapper over events.jsonl")
struct GrokEventsMapperTests {
    @Test("every record kind in the fixture lands on the event it should")
    func census() throws {
        let counts = histogram(try mapped(.events))

        // The one `turn_started` for this session. The one naming another
        // session is skipped, and neither opens a turn — see the mapper.
        #expect(counts["identityUpdated"] == 1)
        #expect(counts["turnStarted"] == nil)
        #expect(counts["turnEnded.complete"] == 1)
        #expect(counts["permissionRequested"] == 2)
        #expect(counts["permissionResolved"] == 2)
        // `mcp_server_failed` and `mcp_oauth_discovery_timeout`. The six
        // `phase_changed` records are silent unless a host asks for them.
        #expect(counts["note"] == 2)
        // The tool pair in this file carries no id on its opening half, so the
        // updates own the whole lifecycle.
        #expect(counts["toolCallStarted"] == nil)
        #expect(counts["toolCallFinished"] == nil)
        #expect(counts["userPrompt"] == nil)
        #expect(counts["usage"] == nil)
    }

    @Test("turn_started names the model and nothing else")
    func model() throws {
        let patches = try mapped(.events).compactMap { event -> SessionIdentityPatch? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch
        }
        #expect(patches.count == 1)
        #expect(patches.first?.model == "grok-example-4")
        // `session_relationship` is `"primary"`, so no variant is invented.
        #expect(patches.first?.variant == nil)
    }

    @Test("a turn_started for another session is not this session's model")
    func foreignTurnStarted() throws {
        let models = try mapped(.events).compactMap { event -> String? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch.model
        }
        #expect(!models.contains("another-sessions-model"))
    }

    @Test("a request and its answer share the id the reducer matches on")
    func permissionPairing() throws {
        let events = try mapped(.events)
        let requests = events.compactMap { event -> (String, String?)? in
            guard case let .permissionRequested(id, tool) = event.kind else { return nil }
            return (id, tool)
        }
        let answers = events.compactMap { event -> (String, Bool)? in
            guard case let .permissionResolved(id, allowed) = event.kind else { return nil }
            return (id, allowed)
        }

        #expect(requests.map(\.0) == ["perm:read_file", "perm:run_terminal_command"])
        #expect(requests.map(\.1) == ["read_file", "run_terminal_command"])
        #expect(answers.map(\.0) == requests.map(\.0))
        // `allow` then `deny`.
        #expect(answers.map(\.1) == [true, false])
    }

    @Test("a decision this table has never seen counts as a refusal")
    func unknownDecision() {
        #expect(GrokRecordMapper.isAllowed("allow"))
        #expect(GrokRecordMapper.isAllowed("allow_always"))
        #expect(GrokRecordMapper.isAllowed("approved"))
        #expect(!GrokRecordMapper.isAllowed("deny"))
        #expect(!GrokRecordMapper.isAllowed("timed_out"))
        #expect(!GrokRecordMapper.isAllowed(nil))
    }

    @Test("phase notes are off by default, and never cover the per-token phases")
    func phaseNotes() throws {
        #expect(notes(try mapped(.events)).allSatisfy { !$0.hasPrefix("phase:") })

        let verbose = try mapped(.events, options: GrokRecordMapper.Options(includePhaseNotes: true))
        let phases = notes(verbose).filter { $0.hasPrefix("phase:") }
        #expect(phases == ["phase: waiting_for_model", "phase: tool_execution", "phase: permission_prompt"])
        // Three `streaming_*` records in the fixture, and not one of them.
        #expect(!phases.contains { $0.contains("streaming") })
    }

    @Test("an MCP server that did not start says so")
    func mcpNotes() throws {
        let texts = notes(try mapped(.events))
        #expect(texts.contains("mcp example-docs: auth_required"))
        #expect(texts.contains("mcp example-tools: oauth discovery timed out"))
    }

    @Test("garbage and untyped lines yield nothing rather than throwing")
    func badLines() {
        #expect(GrokRecordMapper.eventsFromEvents(
            Data("this line is not json at all".utf8), session: grokSession, now: observed).isEmpty)
        #expect(GrokRecordMapper.eventsFromEvents(
            Data(#"{"ts":"2026-01-01T00:00:00.000Z"}"#.utf8),
            session: grokSession, now: observed).isEmpty)
        #expect(GrokEventRecord.decode(Data("".utf8)) == nil)
    }

    @Test("a cancellation category is what makes a turn end aborted")
    func cancelledTurn() {
        let line = Data(
            #"{"ts":"2026-01-01T00:00:09.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"user_escape"}"#
                .utf8)
        let events = GrokRecordMapper.eventsFromEvents(line, session: grokSession, now: observed)
        #expect(events.map { label($0.kind) } == ["turnEnded.aborted"])
    }
}

// MARK: - Mapper: updates.jsonl

@Suite("GrokRecordMapper over updates.jsonl")
struct GrokUpdatesMapperTests {
    @Test("every update kind in the fixture lands on the event it should")
    func census() throws {
        let counts = histogram(try mapped(.updates))

        #expect(counts["userPrompt"] == 1)
        #expect(counts["textBody.user"] == 1)
        #expect(counts["assistantText"] == 2)
        #expect(counts["textBody.assistant"] == 2)
        #expect(counts["thinking"] == 1)
        #expect(counts["toolCallStarted"] == 6)
        #expect(counts["toolCallFinished"] == 6)
        // Five of the six results carry prose. The web search's `rawOutput` is
        // a list of urls and nothing a full-text index would want.
        #expect(counts["textBody.toolResult"] == 5)
        #expect(counts["turnEnded.complete"] == 1)
        #expect(counts["compaction"] == 1)
        // The usage block on `turn_completed` is deliberately not mapped.
        #expect(counts["usage"] == nil)
        #expect(counts["turnStarted"] == nil)
    }

    @Test("a prompt arrives whole, not as a fragment")
    func prompt() throws {
        let previews = try mapped(.updates).compactMap { event -> String? in
            guard case let .userPrompt(preview) = event.kind else { return nil }
            return preview
        }
        #expect(previews == ["Add a regression test for the tailer."])

        let bodies = try mapped(.updates).compactMap { event -> String? in
            guard case let .textBody(role, text, _) = event.kind, role == .user else { return nil }
            return text
        }
        #expect(bodies == ["Add a regression test for the tailer."])
    }

    @Test("each tool call gets the name, kind, and target its record supports")
    func toolCalls() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: starts(try mapped(.updates)).map { ($0.id, $0) })
        #expect(byID.count == 6)

        let read = try #require(byID["call-11111111-0"])
        #expect(read.name == "read_file")
        #expect(read.kind == .fileRead)
        #expect(read.target == "\(grokCwd)/Sources/Tailer.swift")

        let shell = try #require(byID["call-11111111-1"])
        #expect(shell.name == "run_terminal_command")
        #expect(shell.kind == .shell)
        #expect(shell.target == "swift test --filter TailerTests")

        // A backend web search: no tool descriptor, ACP `kind: "search"`, and a
        // title that says web — which is what `ToolKind.web` covers.
        let search = try #require(byID["ws_22222222_call-11111111-2"])
        #expect(search.name == "Web search")
        #expect(search.kind == .web)
        #expect(search.target == nil)

        let fetch = try #require(byID["call-11111111-3"])
        #expect(fetch.name == "web_fetch")
        #expect(fetch.kind == .web)
        #expect(fetch.target == "https://example.test/doc")

        // No descriptor at all: the ACP kind carries it and the title is the
        // only name there is.
        let edit = try #require(byID["call-11111111-4"])
        #expect(edit.kind == .fileWrite)
        #expect(edit.target == "\(grokCwd)/Tests/TailerTests.swift")

        // A namespace that is not the harness's own names an MCP server.
        let mcp = try #require(byID["call-11111111-5"])
        #expect(mcp.name == "search_notes")
        #expect(mcp.kind == .mcp)
        #expect(mcp.target == "example-notes")
    }

    @Test("only a completed or failed update closes a call, and failure is marked")
    func toolCallClosing() throws {
        let finished = try mapped(.updates).compactMap { event -> (String, Bool)? in
            guard case let .toolCallFinished(id, isError) = event.kind else { return nil }
            return (id, isError)
        }
        let byID = Dictionary(finished, uniquingKeysWith: { first, _ in first })
        #expect(byID["call-11111111-0"] == false)
        #expect(byID["call-11111111-1"] == true)
        #expect(byID["ws_22222222_call-11111111-2"] == false)
        #expect(byID["call-11111111-3"] == true)
        #expect(byID["call-11111111-4"] == false)
        #expect(byID["call-11111111-5"] == false)
        // The `in_progress` update and the one carrying no status at all closed
        // nothing, so no call is closed twice.
        #expect(finished.count == 6)
    }

    @Test("a failed call's message reaches the index, filed under its call id")
    func failureBody() throws {
        let bodies = try mapped(.updates).compactMap { event -> (String, String?)? in
            guard case let .textBody(role, text, callID) = event.kind, role == .toolResult
            else { return nil }
            return (text, callID)
        }
        let failure = try #require(bodies.first { $0.1 == "call-11111111-1" })
        #expect(failure.0.contains("declined the prompt"))
        // Every tool-result body names the call it belongs to.
        #expect(bodies.allSatisfy { $0.1 != nil })
    }

    @Test("a line stamped with another session's id is not this session's")
    func foreignSession() throws {
        let previews = try mapped(.updates).compactMap { event -> String? in
            guard case let .userPrompt(preview) = event.kind else { return nil }
            return preview
        }
        #expect(!previews.contains { $0.contains("another session") })
    }

    @Test("timestamps come from the millisecond clock, not the whole second")
    func millisecondClock() throws {
        let first = try #require(try mapped(.updates).first)
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_767_225_601.5))
        #expect(first.observedAt == observed)
    }
}

// MARK: - Mapper: chat_history.jsonl

@Suite("GrokRecordMapper over chat_history.jsonl")
struct GrokChatHistoryMapperTests {
    @Test("only the record a person typed becomes a prompt")
    func prompts() throws {
        let counts = histogram(try mapped(.chatHistory))
        // Three records wear `type: "user"`; one of them is a person.
        #expect(counts["userPrompt"] == 1)
        #expect(counts["textBody.user"] == 1)
        #expect(counts["assistantText"] == 2)
        #expect(counts["textBody.assistant"] == 2)
        #expect(counts["thinking"] == 1)
        // `backend_tool_call` has no id to file a call under and `tool_result`
        // repeats a body the updates already carry.
        #expect(counts["toolCallStarted"] == nil)
        #expect(counts["textBody.toolResult"] == nil)
    }

    @Test("the <user_query> envelope is stripped from what a person typed")
    func envelope() throws {
        let previews = try mapped(.chatHistory).compactMap { event -> String? in
            guard case let .userPrompt(preview) = event.kind else { return nil }
            return preview
        }
        #expect(previews == ["Add a regression test for the tailer."])
        #expect(GrokRecordMapper.unwrapPrompt("<user_query>\nhi\n</user_query>") == "hi")
        // Anything that is not exactly the envelope is left alone.
        #expect(GrokRecordMapper.unwrapPrompt("a <user_query> mid-sentence") == "a <user_query> mid-sentence")
    }

    @Test("records with no clock of their own are stamped with the observation clock")
    func timestamps() throws {
        #expect(try mapped(.chatHistory).allSatisfy { $0.timestamp == observed })
    }
}

// MARK: - Reducer integration

@Suite("Grok events through the reducer")
struct GrokReducerIntegrationTests {
    /// The two tailed files, merged the way ``GrokSessionTailer`` merges them.
    private func merged() throws -> [AgentEvent] {
        var collected: [(file: Int, position: Int, event: AgentEvent)] = []
        for (file, source) in GrokLiveAdapter.defaultTailedFiles.enumerated() {
            for (position, event) in try mapped(source).enumerated() {
                collected.append((file, position, event))
            }
        }
        collected.sort { lhs, rhs in
            if lhs.event.timestamp != rhs.event.timestamp {
                return lhs.event.timestamp < rhs.event.timestamp
            }
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            return lhs.position < rhs.position
        }
        return collected.map(\.event)
    }

    @Test("a whole session folds into an idle row with its calls counted")
    func snapshot() throws {
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: grokSession, sourcePath: "\(grokCwd)/events.jsonl", cwd: grokCwd))
        for event in try merged() {
            snapshot = reducer.reduce(snapshot, event: event)
        }

        #expect(snapshot.state == .idle)
        // One prompt opens one turn; `turn_started` deliberately opens none.
        #expect(snapshot.turnCount == 1)
        #expect(snapshot.toolCallCount == 6)
        #expect(snapshot.identity.model == "grok-example-4")
        #expect(snapshot.pending.openToolCalls.isEmpty)
        #expect(snapshot.pending.openPermission == nil)
        // No usage is emitted, so nothing was billed.
        #expect(snapshot.tokensIn == 0)
        #expect(snapshot.tokensOut == 0)
    }

    @Test("a permission blocks the row and its answer unblocks it")
    func permissionCycle() throws {
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: grokSession, sourcePath: "\(grokCwd)/events.jsonl"))
        var blockedOn: [String?] = []

        for event in try merged() {
            snapshot = reducer.reduce(snapshot, event: event)
            if case let .waitingPermission(tool) = snapshot.state, blockedOn.last != tool {
                blockedOn.append(tool)
            }
        }

        #expect(blockedOn == ["read_file", "run_terminal_command"])
        #expect(snapshot.pending.openPermission == nil)
        if case .waitingPermission = snapshot.state {
            Issue.record("the session is still blocked after both answers arrived")
        }
    }

    @Test("the merge keeps the two files in one non-decreasing timeline")
    func ordering() throws {
        let timestamps = try merged().map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
        // The prompt is in `updates.jsonl` and the permission is in
        // `events.jsonl`; the merge has to put them in that order.
        let events = try merged()
        let prompt = try #require(events.firstIndex { label($0.kind) == "userPrompt" })
        let permission = try #require(events.firstIndex { label($0.kind) == "permissionRequested" })
        #expect(prompt < permission)
    }
}

// MARK: - Percent-encoded session paths

@Suite("GrokSessionsPath")
struct GrokSessionsPathTests {
    @Test("a working directory round-trips through the directory name")
    func roundTrip() throws {
        let encoded = try #require(GrokSessionsPath.encode(cwd: grokCwd))
        #expect(encoded == "%2FUsers%2Fexample%2Fcode%2Fdemo%20app")
        #expect(GrokSessionsPath.decodeCwd(directoryName: encoded) == grokCwd)
    }

    @Test("dots, dashes, tildes, and underscores stay literal")
    func unreserved() throws {
        let path = "/Users/example/.config/my-app_v2~old"
        let encoded = try #require(GrokSessionsPath.encode(cwd: path))
        #expect(encoded == "%2FUsers%2Fexample%2F.config%2Fmy-app_v2~old")
        #expect(GrokSessionsPath.decodeCwd(directoryName: encoded) == path)
    }

    @Test("a name that is not an encoded path answers nil rather than a guess")
    func malformed() {
        #expect(GrokSessionsPath.decodeCwd(directoryName: "") == nil)
        #expect(GrokSessionsPath.decodeCwd(directoryName: "%zz") == nil)
    }
}

// MARK: - A synthetic ~/.grok tree

/// `flock(2)`, reached by symbol because Swift's `flock` names the `struct`
/// that `fcntl` takes. Same technique as `LockFileProbeTests`; an in-process
/// lock is enough here because the adapter only asks *whether* one is held.
private let bsdFlock: @convention(c) (Int32, Int32) -> Int32 = {
    let handle = dlopen(nil, RTLD_NOW)
    return unsafeBitCast(dlsym(handle, "flock"), to: (@convention(c) (Int32, Int32) -> Int32).self)
}()

/// A synthetic `~/.grok`, built out of the fixture files.
private struct GrokHome {
    let tree: TemporaryTree

    var path: String { tree.path }

    /// Copies the fixture session into
    /// `sessions/<encoded cwd>/<session id>/`, and returns that directory.
    @discardableResult
    func session(
        id: String = grokSession.sessionID,
        cwd: String = grokCwd,
        files: [String] = GrokHome.tailedFiles,
        modified: Date? = nil
    ) throws -> URL {
        let encoded = try #require(GrokSessionsPath.encode(cwd: cwd))
        let directory = URL(fileURLWithPath: path)
            .appendingPathComponent(GrokLiveAdapter.sessionsPath)
            .appendingPathComponent(encoded)
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in files {
            let contents = try String(contentsOf: try fixture("session/\(name)"), encoding: .utf8)
            let target = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: target)
            if let modified {
                try FileManager.default.setAttributes(
                    [.modificationDate: modified], ofItemAtPath: target.path)
            }
        }
        return directory
    }

    /// What a session directory holds unless a test asks for more.
    ///
    /// `signals.json` is deliberately not in it: it is rewritten in place many
    /// times a minute, so a test that is about the *logs* should not have a
    /// context reading appearing in the middle of its expectations.
    static let tailedFiles = ["events.jsonl", "updates.jsonl", "chat_history.jsonl", "summary.json"]

    /// Everything a real session directory holds.
    static let everyFile = tailedFiles + ["signals.json"]

    /// Rewrites `signals.json` in place, the way the harness does, and moves
    /// its mtime forward so the change is visible to a stamp comparison.
    func writeSignals(in directory: URL, _ json: String) throws {
        let target = directory.appendingPathComponent("signals.json")
        try Data(json.utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: target.path)
    }

    /// Writes `active_sessions.json`.
    func registry(_ json: String) {
        tree.write(json, to: GrokLiveAdapter.activeSessionsPath)
    }

    /// Creates a writer lock in a session directory and returns its descriptor.
    func lockFile(in directory: URL, named name: String = "chat_history.jsonl.lock") throws -> Int32 {
        let path = directory.appendingPathComponent(name).path
        try Data().write(to: URL(fileURLWithPath: path))
        return open(path, O_RDWR)
    }
}

// MARK: - Discovery

@Suite("GrokLiveAdapter discovery")
struct GrokDiscoveryTests {
    @Test("the directory name is the cwd, and summary.json seeds the rest")
    func seedsIdentity() async throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        let adapter = GrokLiveAdapter()

        let sources = try await adapter.discover(home: home.path, activeSince: .distantPast)
        #expect(sources.count == 1)
        let source = try #require(sources.first)

        // Compared by suffix: `contentsOfDirectory` hands back paths with
        // `/var` resolved to `/private/var`, and which of the two a temporary
        // directory is spelled with is not what this test is about.
        let relative = "\(directory.lastPathComponent)"
        #expect(source.key == grokSession)
        #expect(source.primaryPath.hasSuffix("\(relative)/events.jsonl"))
        #expect(source.auxiliaryPaths.map { ($0 as NSString).lastPathComponent }
            == ["updates.jsonl", "chat_history.jsonl"])
        #expect(source.auxiliaryPaths.allSatisfy { $0.contains(relative) })
        #expect(source.seedIdentity.cwd == grokCwd)
        #expect(source.seedIdentity.title == "Tailer regression test")
        #expect(source.seedIdentity.model == "grok-example-4")
        #expect(source.seedIdentity.entrypoint == "grok-build-plan")
    }

    @Test("a session untouched since the cutoff is not worth tailing")
    func cutoff() async throws {
        let home = GrokHome(tree: TemporaryTree())
        try home.session(modified: Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = GrokLiveAdapter()

        let sources = try await adapter.discover(
            home: home.path, activeSince: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(sources.isEmpty)
    }

    @Test("a session the registry names is found however old its files are")
    func registryOverridesTheCutoff() async throws {
        let home = GrokHome(tree: TemporaryTree())
        try home.session(modified: Date(timeIntervalSince1970: 1_700_000_000))
        home.registry(
            #"[{"session_id":"\#(grokSession.sessionID)","pid":4711,"cwd":"\#(grokCwd)","opened_at":"2026-01-01T00:00:00Z"}]"#
        )
        let adapter = GrokLiveAdapter()

        let sources = try await adapter.discover(
            home: home.path, activeSince: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(sources.map(\.key) == [grokSession])
    }

    @Test("a summary that names a different session is not that session's directory")
    func idDisagreement() async throws {
        let home = GrokHome(tree: TemporaryTree())
        try home.session(id: "99999999-8888-7777-6666-555555555555")
        let adapter = GrokLiveAdapter()

        #expect(try await adapter.discover(home: home.path, activeSince: .distantPast).isEmpty)
    }

    @Test("a directory with none of a session's files in it is not a session")
    func emptyDirectory() async throws {
        let home = GrokHome(tree: TemporaryTree())
        try home.session(files: [])
        let adapter = GrokLiveAdapter()

        #expect(try await adapter.discover(home: home.path, activeSince: .distantPast).isEmpty)
    }

    @Test("the watch roots are the session tree and the registry, and nothing wider")
    func watchRoots() {
        let roots = GrokLiveAdapter().watchRoots(home: "/Users/example").map(\.path)
        #expect(roots == [
            "/Users/example/.grok/sessions",
            "/Users/example/.grok/active_sessions.json"
        ])
    }

    @Test("a missing home is an empty answer, not a throw")
    func missingHome() async throws {
        let adapter = GrokLiveAdapter()
        #expect(try await adapter.discover(
            home: "/Users/example/nowhere", activeSince: .distantPast).isEmpty)
    }
}

// MARK: - The fan-out tailer

@Suite("GrokSessionTailer")
struct GrokSessionTailerTests {
    private func tailer(
        _ home: GrokHome,
        directory: URL,
        cursor: SourceCursor? = nil
    ) -> GrokSessionTailer {
        let identity = SessionIdentity(
            key: grokSession, sourcePath: directory.appendingPathComponent("events.jsonl").path)
        let source = SessionSource(
            key: grokSession,
            primaryPath: identity.sourcePath,
            auxiliaryPaths: [
                directory.appendingPathComponent("updates.jsonl").path,
                directory.appendingPathComponent("chat_history.jsonl").path
            ],
            seedIdentity: identity
        )
        return GrokSessionTailer(source: source, cursor: cursor, clock: { observed })
    }

    @Test("the two tailed files come back as one timeline with one sequence")
    func interleaves() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        let events = try tailer(home, directory: directory).poll()

        #expect(!events.isEmpty)
        #expect(events.map(\.timestamp) == events.map(\.timestamp).sorted())
        #expect(events.map(\.sequence) == Array(1...Int64(events.count)))

        // Both files are represented, and `chat_history.jsonl` is not.
        let paths = Set(events.compactMap { $0.raw?.path })
        #expect(paths.contains(directory.appendingPathComponent("events.jsonl").path))
        #expect(paths.contains(directory.appendingPathComponent("updates.jsonl").path))
        #expect(!paths.contains(directory.appendingPathComponent("chat_history.jsonl").path))
    }

    @Test("the whole file's worth of events is what the mapper produced")
    func matchesTheMapper() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        let counts = histogram(try tailer(home, directory: directory).poll())

        #expect(counts["userPrompt"] == 1)
        #expect(counts["toolCallStarted"] == 6)
        #expect(counts["toolCallFinished"] == 6)
        #expect(counts["permissionRequested"] == 2)
        // One from `updates.turn_completed`, one from `events.turn_ended`.
        #expect(counts["turnEnded.complete"] == 2)
    }

    @Test("a composite cursor survives a round trip and resumes without repeating")
    func cursorRoundTrip() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()

        let first = tailer(home, directory: directory)
        let seen = try first.poll()
        #expect(!seen.isEmpty)

        guard case let .composite(parts) = first.cursor else {
            Issue.record("a fan-out tailer must produce a composite cursor")
            return
        }
        #expect(parts.count == 2)

        let encoded = try JSONEncoder().encode(first.cursor)
        let decoded = try JSONDecoder().decode(SourceCursor.self, from: encoded)
        #expect(decoded == first.cursor)

        // Resuming from it re-reads nothing.
        let resumed = tailer(home, directory: directory, cursor: decoded)
        #expect(try resumed.poll().isEmpty)

        // And a line appended to one file comes back on its own.
        let line = #"{"ts":"2026-01-01T00:00:20.000Z","type":"permission_requested","tool_name":"write"}"# + "\n"
        let handle = try #require(
            FileHandle(forWritingAtPath: directory.appendingPathComponent("events.jsonl").path))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        let more = try resumed.poll()
        #expect(more.map { label($0.kind) } == ["permissionRequested"])
        #expect(more.first?.sequence == 1)
    }

    @Test("a cold-start seed splits its budget across the files it reads")
    func seed() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        let tailer = tailer(home, directory: directory)

        let seeded = try tailer.seedFromTail(maxBytes: 64 * 1024)
        #expect(!seeded.isEmpty)
        #expect(seeded.map(\.timestamp) == seeded.map(\.timestamp).sorted())
        // The seed leaves the cursor at the end, so nothing repeats.
        #expect(try tailer.poll().isEmpty)
    }

    @Test("the adapter can be asked to tail chat_history.jsonl instead")
    func alternativeFileSet() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        let identity = SessionIdentity(
            key: grokSession, sourcePath: directory.appendingPathComponent("events.jsonl").path)
        let source = SessionSource(
            key: grokSession, primaryPath: identity.sourcePath, seedIdentity: identity)

        let tailer = GrokSessionTailer(
            source: source, cursor: nil, files: [.chatHistory], clock: { observed })
        #expect(tailer.paths == [directory.appendingPathComponent("chat_history.jsonl").path])

        let counts = histogram(try tailer.poll())
        #expect(counts["userPrompt"] == 1)
        #expect(counts["assistantText"] == 2)
    }

    @Test("signals.json becomes a context reading, once per rewrite")
    func contextLevel() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session(files: GrokHome.everyFile)
        let tailer = tailer(home, directory: directory)

        let readings = contextReadings(try tailer.poll())
        #expect(readings.count == 1)
        // `contextTokensUsed` out of `contextWindowTokens`, as the harness
        // computed them. Nothing derived, and no cached share on offer.
        #expect(readings.first?.used == 12_900)
        #expect(readings.first?.window == 500_000)
        #expect(readings.first?.cached == nil)
        #expect(readings.first?.source == .measured)

        // The file is rewritten in place, so an unchanged one is not a second
        // reading — a poll that changes nothing costs one stat and says
        // nothing.
        #expect(contextReadings(try tailer.poll()).isEmpty)

        try home.writeSignals(
            in: directory,
            #"{"contextTokensUsed":410000,"contextWindowTokens":500000,"compactionCount":2}"#
        )
        let after = contextReadings(try tailer.poll())
        #expect(after.map(\.used) == [410_000])
    }

    @Test("a session with no signals.json tails exactly as it did before")
    func withoutSignals() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        #expect(contextReadings(try tailer(home, directory: directory).poll()).isEmpty)
    }

    @Test("signals.json with no context counters in it says nothing")
    func signalsWithoutContext() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        try home.writeSignals(in: directory, #"{"turnCount":3,"toolCallCount":9}"#)
        #expect(contextReadings(try tailer(home, directory: directory).poll()).isEmpty)
    }

    @Test("a cold-start seed carries the level too")
    func seedCarriesTheLevel() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session(files: GrokHome.everyFile)
        let tailer = tailer(home, directory: directory)
        #expect(contextReadings(try tailer.seedFromTail(maxBytes: 64 * 1024)).count == 1)
        // And the seed consumed it, so the poll behind it does not repeat it.
        #expect(contextReadings(try tailer.poll()).isEmpty)
    }

    @Test("a session whose files are not there yet polls empty rather than throwing")
    func missingFiles() throws {
        let tree = TemporaryTree()
        let identity = SessionIdentity(
            key: grokSession, sourcePath: tree.file("nowhere/events.jsonl").path)
        let source = SessionSource(
            key: grokSession, primaryPath: identity.sourcePath, seedIdentity: identity)
        let tailer = GrokSessionTailer(source: source, cursor: nil, clock: { observed })

        #expect(try tailer.poll().isEmpty)
        #expect(try tailer.seedFromTail(maxBytes: 4096).isEmpty)
    }
}

// MARK: - Liveness

@Suite("GrokLiveAdapter liveness", .serialized)
struct GrokLivenessTests {
    private func identity(_ directory: URL) -> SessionIdentity {
        SessionIdentity(
            key: grokSession, sourcePath: directory.appendingPathComponent("events.jsonl").path)
    }

    private func table(pids: [pid_t]) -> FakeProcessTable {
        FakeProcessTable(
            records: pids.map {
                ProcessRecord(
                    pid: $0, ppid: 1, startTime: observed, executablePath: "/usr/local/bin/grok",
                    argv: ["grok"])
            })
    }

    @Test("a registered session whose pid is running is alive")
    func registeredAndRunning() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        home.registry(
            #"[{"session_id":"\#(grokSession.sessionID)","pid":4711,"cwd":"\#(grokCwd)","opened_at":"2026-01-01T00:00:00Z"}]"#
        )

        let hint = GrokLiveAdapter().probeLiveness(
            identity(directory), table: table(pids: [4711]), home: home.path)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4711)
        #expect(hint.evidence.contains("4711"))
    }

    @Test("a registry entry that outlived its process is death, not life")
    func staleRegistryEntry() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        home.registry(#"[{"session_id":"\#(grokSession.sessionID)","pid":4711,"cwd":"\#(grokCwd)"}]"#)

        let hint = GrokLiveAdapter().probeLiveness(
            identity(directory), table: table(pids: [99]), home: home.path)
        #expect(hint.verdict == .dead)
        #expect(hint.pid == 4711)
    }

    @Test("an entry with no pid still says the session is running")
    func registryWithoutAPid() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        home.registry(#"["\#(grokSession.sessionID)"]"#)

        let hint = GrokLiveAdapter().probeLiveness(
            identity(directory), table: table(pids: []), home: home.path)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == nil)
    }

    @Test("a held writer lock is alive even with an empty registry")
    func heldLock() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session()
        home.registry("[]")

        let descriptor = try home.lockFile(in: directory)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(bsdFlock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let hint = GrokLiveAdapter().probeLiveness(
            identity(directory), table: table(pids: []), home: home.path)
        #expect(hint.verdict == .alive)
        // Grok is Rust: the kernel will not name a `flock(2)` owner.
        #expect(hint.pid == nil)
        #expect(hint.evidence.contains("flock"))
    }

    @Test("a lock file that is present but released says nothing on its own")
    func releasedLock() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session(modified: observed.addingTimeInterval(-30))
        home.registry("[]")
        let descriptor = try home.lockFile(in: directory)
        close(descriptor)

        let hint = GrokLiveAdapter(clock: { observed }).probeLiveness(
            identity(directory), table: table(pids: []), home: home.path)
        #expect(hint.verdict == .unknown)
    }

    @Test("no registry, no lock, and a quiet directory is dead")
    func quiet() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session(modified: observed.addingTimeInterval(-3600))

        let hint = GrokLiveAdapter(clock: { observed }).probeLiveness(
            identity(directory), table: table(pids: []), home: home.path)
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("quiet"))
    }

    @Test("no registry, no lock, but a directory written a moment ago is unknown")
    func recentlyWritten() throws {
        let home = GrokHome(tree: TemporaryTree())
        let directory = try home.session(modified: observed.addingTimeInterval(-30))

        let hint = GrokLiveAdapter(clock: { observed }).probeLiveness(
            identity(directory), table: table(pids: []), home: home.path)
        #expect(hint.verdict == .unknown)
    }

    @Test("a session directory that is not there answers unknown")
    func missingDirectory() {
        let tree = TemporaryTree()
        let identity = SessionIdentity(
            key: grokSession, sourcePath: tree.file("nowhere/events.jsonl").path)
        let hint = GrokLiveAdapter().probeLiveness(
            identity, table: table(pids: []), home: tree.path)
        #expect(hint.verdict == .unknown)
    }

    @Test("a corrupt registry is an empty one, exactly as the harness treats it")
    func corruptRegistry() throws {
        let home = GrokHome(tree: TemporaryTree())
        try home.session(modified: observed.addingTimeInterval(-30))
        home.registry("{ not json")
        #expect(GrokActiveSessions.read(home: home.path).isEmpty)
    }
}

// MARK: - Fixture hygiene

@Suite("Grok fixtures")
struct GrokFixtureHygieneTests {
    @Test("no real home directory reached a fixture")
    func onlyExampleUsers() throws {
        let root = try fixture(".")
        let files = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

        var checked = 0
        for case let url as URL in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            var rest = Substring(text)
            while let found = rest.range(of: "/Users/") {
                let after = rest[found.upperBound...]
                #expect(
                    after.hasPrefix("example"),
                    "\(url.lastPathComponent) names a home other than /Users/example")
                rest = after
            }
        }
        #expect(checked >= 5)
    }
}
