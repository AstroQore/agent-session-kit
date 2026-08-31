import AgentSessionKit
import Darwin
import Foundation
import Testing

@testable import AgentSessionLive

// MARK: - Fixtures

private let agentID = "ef677032-4618-4f13-9ffa-fded8574b84d"
private let otherAgentID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
private let session = SessionKey(harness: .cursor, sessionID: agentID)
private let workspaceHash = "0af52b5f862f8eb7689b0795c4f131f8"
private let projectCWD = "/Users/example/code/reducer"
private let projectSlug = "Users-example-code-reducer"

/// A fixed observation clock, so nothing in the suite depends on today.
private let observed = Date(timeIntervalSince1970: 1_800_000_000)

private enum Ids {
    static let root1 = CursorFixture.BlobID(seed: 0x11)
    static let root2 = CursorFixture.BlobID(seed: 0x12)
    static let user1 = CursorFixture.BlobID(seed: 0x21)
    static let call1 = CursorFixture.BlobID(seed: 0x22)
    static let result1 = CursorFixture.BlobID(seed: 0x23)
    static let reply1 = CursorFixture.BlobID(seed: 0x24)
    static let user2 = CursorFixture.BlobID(seed: 0x25)
    static let reply2 = CursorFixture.BlobID(seed: 0x26)
}

private let turnOneBlobs: [CursorFixture.Blob] = [
    CursorFixture.Blob(id: Ids.root1, data: CursorFixture.node(
        references: [Ids.user1, Ids.call1, Ids.result1, Ids.reply1],
        workspaceURI: "file:///Users/example/code/reducer",
        surface: "cli",
        timestampMillis: 1_787_040_000_000
    )),
    CursorFixture.Blob(id: Ids.user1, message: CursorFixture.userMessage("add a test for the reducer")),
    CursorFixture.Blob(id: Ids.call1, message: CursorFixture.assistantMessage([
        CursorFixture.reasoningPart("the reducer is pure, so a table test will do"),
        CursorFixture.toolCallPart(id: "call_1", name: "run_terminal_cmd", args: ["command": "swift test"])
    ])),
    CursorFixture.Blob(id: Ids.result1, message: CursorFixture.toolResultMessage(
        id: "call_1", result: ["stdout": "3 tests passed"]
    )),
    CursorFixture.Blob(id: Ids.reply1, message: CursorFixture.assistantMessage(
        [CursorFixture.textPart("The suite is green.")], model: "composer-1"
    ))
]

/// A second turn, written the way Cursor writes one: a new head node that
/// re-lists every message, old ids included.
private let turnTwoBlobs: [CursorFixture.Blob] = [
    CursorFixture.Blob(id: Ids.root2, data: CursorFixture.node(
        references: [Ids.user1, Ids.call1, Ids.result1, Ids.reply1, Ids.user2, Ids.reply2],
        workspaceURI: "file:///Users/example/code/reducer",
        surface: "cli"
    )),
    CursorFixture.Blob(id: Ids.user2, message: CursorFixture.userMessage("now make the walk incremental")),
    CursorFixture.Blob(id: Ids.reply2, message: CursorFixture.assistantMessage(
        [CursorFixture.textPart("Cached the visit set.")], model: "composer-1"
    ))
]

/// Builds `~/.cursor/chats/<hash>/<agent>/store.db` with turn one in it.
@discardableResult
private func writeTurnOne(
    _ tree: TemporaryTree,
    agentID: String = agentID,
    workspaceHash: String = workspaceHash,
    name: String? = "Wire up the reducer"
) throws -> URL {
    try CursorFixture.writeStore(
        home: tree.url,
        agentID: agentID,
        workspaceHash: workspaceHash,
        card: CursorFixture.card(agentID: agentID, root: Ids.root1, name: name),
        blobs: turnOneBlobs
    )
}

private func appendTurnTwo(_ store: URL, agentID: String = agentID) throws {
    try CursorFixture.appendTurn(
        store: store,
        card: CursorFixture.card(agentID: agentID, root: Ids.root2, name: "Wire up the reducer"),
        blobs: turnTwoBlobs
    )
}

/// A stable label per event case, for counting a whole poll at once.
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

private func previews(_ events: [AgentEvent]) -> [String] {
    events.compactMap {
        switch $0.kind {
        case let .userPrompt(preview): preview
        case let .assistantText(preview): preview
        default: nil
        }
    }
}

private func bodies(_ events: [AgentEvent]) -> [String] {
    events.compactMap {
        guard case let .textBody(_, text, _) = $0.kind else { return nil }
        return text
    }
}

/// A temporary directory is reached through a symlink on macOS
/// (`/var` → `/private/var`), and `contentsOfDirectory(at:)` resolves it while
/// a hand-built `URL` does not. Compare the resolved form or compare nothing.
private func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func storeEvents(
    _ store: URL,
    emitsUserPrompt: Bool = true
) -> [AgentEvent] {
    let reader = CursorStoreReader(path: store.path)
    guard let root = reader.readMeta()?.latestRootBlobID else { return [] }
    let walk = reader.walk(from: root)
    return reader.decode(walk.messages).flatMap {
        CursorMessageMapper.events(
            from: $0, session: session, now: observed, emitsUserPrompt: emitsUserPrompt
        )
    }
}

// MARK: - The reader

@Suite("CursorStoreReader over a synthetic store")
struct CursorStoreReaderTests {
    @Test("the card decodes out of the hex-encoded meta row")
    func card() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let meta = try #require(CursorStoreReader(path: store.path).readMeta())

        #expect(meta.agentID == agentID)
        #expect(meta.latestRootBlobID == Ids.root1.hex)
        #expect(meta.name == "Wire up the reducer")
        #expect(meta.mode == "agent")
        #expect(meta.displayTitle == "Wire up the reducer")
    }

    @Test("a name Cursor invented is not a title")
    func genericName() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree, name: "New Agent")
        #expect(CursorStoreReader(path: store.path).readMeta()?.displayTitle == nil)
    }

    @Test("the walk yields messages in conversation order")
    func walkOrder() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let reader = CursorStoreReader(path: store.path)
        let walk = reader.walk(from: Ids.root1.hex)

        #expect(walk.messages.map(\.blobID) == [
            Ids.user1.hex, Ids.call1.hex, Ids.result1.hex, Ids.reply1.hex
        ])
        #expect(walk.messages.allSatisfy { $0.partIndex == 0 })
        #expect(walk.visited.first == Ids.root1.hex)
        #expect(!walk.truncated)

        let decoded = reader.decode(walk.messages)
        #expect(decoded.map(\.role) == ["user", "assistant", "tool", "assistant"])
    }

    @Test("a second walk with the previous visit set decodes only the new turn")
    func incrementalWalk() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let reader = CursorStoreReader(path: store.path)
        let first = reader.walk(from: Ids.root1.hex)
        try appendTurnTwo(store)

        let second = reader.walk(from: Ids.root2.hex, seen: Set(first.visited))
        #expect(second.messages.map(\.blobID) == [Ids.user2.hex, Ids.reply2.hex])
        // Only the new head and the two new messages were fetched at all.
        #expect(Set(second.visited) == [Ids.root2.hex, Ids.user2.hex, Ids.reply2.hex])
    }

    @Test("a head that chains to its predecessor walks incrementally too")
    func chainedHead() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let reader = CursorStoreReader(path: store.path)
        let first = reader.walk(from: Ids.root1.hex)

        // The other shape a head can take: reference the old head plus what
        // is new, rather than re-listing the conversation.
        try CursorFixture.appendTurn(
            store: store,
            card: CursorFixture.card(agentID: agentID, root: Ids.root2),
            blobs: [
                CursorFixture.Blob(id: Ids.root2, data: CursorFixture.node(
                    references: [Ids.root1, Ids.user2]
                )),
                CursorFixture.Blob(id: Ids.user2, message: CursorFixture.userMessage("and again"))
            ]
        )

        let second = reader.walk(from: Ids.root2.hex, seen: Set(first.visited))
        #expect(second.messages.map(\.blobID) == [Ids.user2.hex])
    }

    @Test("a message inlined into a node is found by index")
    func inlineMessages() throws {
        let tree = TemporaryTree()
        let inline = CursorFixture.BlobID(seed: 0x31)
        let store = try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: CursorFixture.card(agentID: agentID, root: Ids.root1),
            blobs: [
                CursorFixture.Blob(id: Ids.root1, data: CursorFixture.node(references: [inline])),
                CursorFixture.Blob(id: inline, data: CursorFixture.node(inlineMessages: [
                    CursorFixture.userMessage("first"),
                    CursorFixture.assistantMessage([CursorFixture.textPart("second")], model: "composer-1")
                ]))
            ]
        )
        let reader = CursorStoreReader(path: store.path)
        let walk = reader.walk(from: Ids.root1.hex)

        #expect(walk.messages == [
            CursorMessageRef(blobID: inline.hex, partIndex: 0),
            CursorMessageRef(blobID: inline.hex, partIndex: 1)
        ])
        let decoded = reader.decode(walk.messages)
        #expect(decoded.map(\.role) == ["user", "assistant"])
        #expect(decoded.last?.model == "composer-1")
        #expect(decoded.map(\.ref.anchor) == ["\(inline.hex).0", "\(inline.hex).1"])
    }

    @Test("a dangling reference is skipped and a cycle terminates")
    func hostileGraph() throws {
        let tree = TemporaryTree()
        let missing = CursorFixture.BlobID(seed: 0x66)
        let back = CursorFixture.BlobID(seed: 0x67)
        let store = try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: CursorFixture.card(agentID: agentID, root: Ids.root1),
            blobs: [
                CursorFixture.Blob(id: Ids.root1, data: CursorFixture.node(
                    references: [missing, back, Ids.user1]
                )),
                CursorFixture.Blob(id: back, data: CursorFixture.node(references: [Ids.root1])),
                CursorFixture.Blob(id: Ids.user1, message: CursorFixture.userMessage("still here"))
            ]
        )
        let walk = CursorStoreReader(path: store.path).walk(from: Ids.root1.hex)
        #expect(walk.messages.map(\.blobID) == [Ids.user1.hex])
    }

    @Test("a store in WAL mode still reads")
    func walMode() throws {
        let tree = TemporaryTree()
        let store = try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: CursorFixture.card(agentID: agentID, root: Ids.root1),
            blobs: turnOneBlobs,
            walMode: true
        )
        #expect(CursorStoreReader(path: store.path).readMeta()?.agentID == agentID)
        #expect(CursorStoreReader(path: store.path).walk(from: Ids.root1.hex).messages.count == 4)
    }

    @Test("a store that is not there answers nothing rather than throwing")
    func missingStore() {
        let reader = CursorStoreReader(path: "/nonexistent/store.db")
        #expect(reader.readMeta() == nil)
        #expect(reader.walk(from: Ids.root1.hex).messages.isEmpty)
        #expect(reader.decode([CursorMessageRef(blobID: Ids.user1.hex)]).isEmpty)
    }
}

// MARK: - The message mapper

@Suite("CursorMessageMapper")
struct CursorMessageMapperTests {
    @Test("a whole turn lands on the events it should")
    func census() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let counts = histogram(storeEvents(store))

        #expect(counts["userPrompt"] == 1)
        #expect(counts["textBody.user"] == 1)
        #expect(counts["thinking"] == 1)
        #expect(counts["toolCallStarted"] == 1)
        #expect(counts["toolCallFinished"] == 1)
        #expect(counts["textBody.toolResult"] == 1)
        #expect(counts["assistantText"] == 1)
        #expect(counts["textBody.assistant"] == 1)
        #expect(counts["identityUpdated"] == 1)
        // The store records no turn boundary at all; that is the thin
        // transcript's job.
        #expect(counts["turnEnded.complete"] == nil)
        #expect(counts["turnStarted"] == nil)
    }

    @Test("the prompt wrapper comes off and the header dates the turn")
    func promptEnvelope() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let events = storeEvents(store)

        #expect(previews(events).first == "add a test for the reducer")
        #expect(bodies(events).first == "add a test for the reducer")
        let prompt = try #require(events.first { label($0.kind) == "userPrompt" })
        #expect(prompt.timestamp == CursorFixture.promptStampDate)
        #expect(prompt.observedAt == observed)
    }

    @Test("a message with no clock of its own is stamped with the observation clock")
    func fallbackTimestamp() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let reply = try #require(storeEvents(store).first { label($0.kind) == "assistantText" })
        #expect(reply.timestamp == observed)
    }

    @Test("the tool call and its result pair on the harness's own id")
    func toolPairing() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let events = storeEvents(store)

        let started = try #require(events.compactMap { event -> (String, String, ToolKind, String?)? in
            guard case let .toolCallStarted(id, name, kind, target) = event.kind else { return nil }
            return (id, name, kind, target)
        }.first)
        #expect(started.0 == "call_1")
        #expect(started.1 == "run_terminal_cmd")
        #expect(started.2 == .shell)
        #expect(started.3 == "swift test")

        let finished = try #require(events.compactMap { event -> (String, Bool)? in
            guard case let .toolCallFinished(id, isError) = event.kind else { return nil }
            return (id, isError)
        }.first)
        #expect(finished == ("call_1", false))

        let body = try #require(events.compactMap { event -> (String, String)? in
            guard case let .textBody(role, text, callID) = event.kind, role == .toolResult else {
                return nil
            }
            return (text, callID ?? "")
        }.first)
        #expect(body.1 == "call_1")
        #expect(body.0.contains("3 tests passed"))
    }

    @Test("a failing tool result is reported as one")
    func toolFailure() {
        let object = try! JSONSerialization.jsonObject(
            with: Data(CursorFixture.toolResultMessage(
                id: "call_9", result: ["error": "exit 1"], isError: true
            ).utf8)
        ) as! [String: Any]
        let message = try! #require(
            CursorMessage.decode(object, ref: CursorMessageRef(blobID: Ids.result1.hex))
        )
        let events = CursorMessageMapper.events(from: message, session: session, now: observed)
        let finished = events.compactMap { event -> Bool? in
            guard case let .toolCallFinished(_, isError) = event.kind else { return nil }
            return isError
        }
        #expect(finished == [true])
    }

    @Test("reasoning becomes a state and never carries its text")
    func reasoningIsOpaque() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let events = storeEvents(store)
        #expect(histogram(events)["thinking"] == 1)
        #expect(!bodies(events).contains { $0.contains("weighing") })
        #expect(!previews(events).contains { $0.contains("two options") })
    }

    @Test("a system message is dropped whole")
    func systemDropped() {
        let object = try! JSONSerialization.jsonObject(
            with: Data(CursorFixture.systemMessage("the assembled rules go here").utf8)
        ) as! [String: Any]
        let message = try! #require(
            CursorMessage.decode(object, ref: CursorMessageRef(blobID: Ids.user1.hex))
        )
        #expect(CursorMessageMapper.events(from: message, session: session, now: observed).isEmpty)
    }

    @Test("the caller decides who owns userPrompt")
    func promptOwnership() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let counts = histogram(storeEvents(store, emitsUserPrompt: false))
        #expect(counts["userPrompt"] == nil)
        // The full text stays the store's either way.
        #expect(counts["textBody.user"] == 1)
    }

    @Test("the model is read off the assistant part that carries it")
    func model() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let patch = try #require(storeEvents(store).compactMap { event -> SessionIdentityPatch? in
            guard case let .identityUpdated(patch) = event.kind else { return nil }
            return patch
        }.first)
        #expect(patch.model == "composer-1")
    }
}

// MARK: - The tool table

@Suite("CursorToolMapping")
struct CursorToolMappingTests {
    @Test("every tool name Cursor ships lands on the activity it is")
    func kinds() {
        let cases: [(String, [String: String], ToolKind, String?)] = [
            ("run_terminal_cmd", ["command": "swift build"], .shell, "swift build"),
            ("shell", ["command": "ls"], .shell, "ls"),
            ("read_file", ["target_file": "Sources/App.swift"], .fileRead, "Sources/App.swift"),
            ("list_dir", ["path": "Sources"], .fileRead, "Sources"),
            ("grep", ["pattern": "TODO"], .search, "TODO"),
            ("codebase_search", ["query": "where is the reducer"], .search, "where is the reducer"),
            ("glob_file_search", ["glob_pattern": "**/*.swift"], .search, "**/*.swift"),
            ("edit_file", ["target_file": "Sources/App.swift"], .fileWrite, "Sources/App.swift"),
            ("write", ["path": "notes.md"], .fileWrite, "notes.md"),
            ("delete_file", ["file_path": "old.swift"], .fileWrite, "old.swift"),
            ("web_search", ["query": "swift testing"], .web, "swift testing"),
            ("fetch", ["url": "https://example.com"], .web, "https://example.com"),
            ("mcp_github_create_issue", [:], .mcp, "github"),
            ("task", ["description": "explore the store"], .subagent, "explore the store"),
            ("todo_write", ["description": "three items"], .plan, "three items"),
            ("something_new", [:], .other, nil)
        ]
        for (name, arguments, kind, target) in cases {
            let resolved = CursorToolMapping.resolve(name: name, arguments: arguments)
            #expect(resolved.kind == kind, "\(name) resolved to \(resolved.kind)")
            #expect(resolved.target == target, "\(name) targeted \(resolved.target ?? "nil")")
        }
    }

    @Test("a tool call's arguments are narrowed to a whitelist")
    func argumentWhitelist() {
        let narrowed = CursorMessage.arguments([
            "target_file": "Sources/App.swift",
            "code_edit": String(repeating: "x", count: 100_000),
            "instructions": "rewrite the file"
        ])
        #expect(narrowed == ["target_file": "Sources/App.swift"])
    }
}

// MARK: - The prompt envelope

@Suite("CursorPromptText")
struct CursorPromptTextTests {
    @Test("the timestamp header parses in the zone it names")
    func header() {
        #expect(CursorPromptText.parse("Tuesday, Aug 18, 2026, 5:39 PM (UTC+8)")
            == CursorFixture.promptStampDate)
        // Same instant, written from a different zone.
        #expect(CursorPromptText.parse("Tuesday, Aug 18, 2026, 9:39 AM (UTC)")
            == CursorFixture.promptStampDate)
        #expect(CursorPromptText.parse("Tuesday, Aug 18, 2026, 5:09 PM (UTC+7:30)")
            == CursorFixture.promptStampDate)
        #expect(CursorPromptText.parse("Tuesday, Aug 18, 2026, 5:39 PM (UTC+0800)")
            == CursorFixture.promptStampDate)
    }

    @Test("midnight and noon survive the twelve-hour clock")
    func meridiem() throws {
        let midnight = try #require(CursorPromptText.parse("Sunday, Jan 4, 2026, 12:00 AM (UTC)"))
        let noon = try #require(CursorPromptText.parse("Sunday, Jan 4, 2026, 12:00 PM (UTC)"))
        #expect(noon.timeIntervalSince(midnight) == 12 * 3600)
    }

    @Test("anything that is not the header shape yields nothing")
    func rejects() {
        #expect(CursorPromptText.parse("") == nil)
        #expect(CursorPromptText.parse("yesterday") == nil)
        #expect(CursorPromptText.parse("Tuesday, Aug 18, 2026") == nil)
        #expect(CursorPromptText.parse("Tuesday, Xyz 18, 2026, 5:39 PM (UTC+8)") == nil)
    }

    @Test("the wrapper comes off, and text without one is left alone")
    func body() {
        #expect(CursorPromptText.body(CursorFixture.promptText("centre the hero")) == "centre the hero")
        #expect(CursorPromptText.body("<user_query>\njust the wrapper\n</user_query>")
            == "just the wrapper")
        #expect(CursorPromptText.body("no wrapper at all") == "no wrapper at all")
        #expect(CursorPromptText.body("") == "")
    }

    @Test("the header is found inside a prompt, not only alone")
    func headerInPrompt() {
        #expect(CursorPromptText.timestamp(in: CursorFixture.promptText("hello"))
            == CursorFixture.promptStampDate)
        #expect(CursorPromptText.timestamp(in: "hello") == nil)
    }
}

// MARK: - The thin transcript

@Suite("CursorThinTranscriptMapper")
struct CursorThinTranscriptMapperTests {
    private func mapped(_ line: String) -> [AgentEvent] {
        CursorThinTranscriptMapper.events(from: Data(line.utf8), session: session, now: observed)
    }

    @Test("a user line opens the turn and carries the header's clock")
    func userLine() throws {
        let events = mapped(CursorFixture.transcriptUserLine("add a test for the reducer"))
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(label(event.kind) == "userPrompt")
        #expect(previews(events) == ["add a test for the reducer"])
        #expect(event.timestamp == CursorFixture.promptStampDate)
        #expect(event.observedAt == observed)
    }

    @Test("an assistant line is the store's to report")
    func assistantLine() {
        #expect(mapped(CursorFixture.transcriptAssistantLine("The suite is green.")).isEmpty)
    }

    @Test("turn_ended carries its status across")
    func turnEnded() {
        let statuses: [(String, TurnEndReason)] = [
            ("success", .complete), ("error", .error), ("aborted", .aborted), ("who knows", .unknown)
        ]
        for (status, reason) in statuses {
            let events = mapped(CursorFixture.transcriptTurnEnded(status))
            #expect(histogram(events) == ["turnEnded.\(reason.rawValue)": 1])
        }
    }

    @Test("the committed record shape maps end to end")
    func fixtureFile() throws {
        let url = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/cursor/thin-transcript.jsonl")
        try #require(FileManager.default.fileExists(atPath: url.path), "missing the cursor fixture")

        let events = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .flatMap {
                CursorThinTranscriptMapper.events(
                    from: Data($0.utf8), session: session, now: observed
                )
            }
        #expect(histogram(events) == ["userPrompt": 1, "turnEnded.complete": 1])
        #expect(previews(events) == ["add a test for the reducer"])
    }

    @Test("garbage and unknown shapes yield nothing rather than stopping the tail")
    func garbage() {
        #expect(mapped("not json at all").isEmpty)
        #expect(mapped("{}").isEmpty)
        #expect(mapped(#"{"role":"user","message":{"content":[]}}"#).isEmpty)
        #expect(mapped(#"{"type":"something_new"}"#).isEmpty)
    }
}

// MARK: - The tailer

@Suite("CursorSessionTailer")
struct CursorSessionTailerTests {
    private func source(store: URL, transcript: String? = nil) -> SessionSource {
        var identity = SessionIdentity(key: session, sourcePath: store.path)
        identity.cwd = projectCWD
        return SessionSource(
            key: session,
            primaryPath: store.path,
            auxiliaryPaths: transcript.map { [$0] } ?? [],
            seedIdentity: identity
        )
    }

    private func tailer(_ source: SessionSource, cursor: SourceCursor? = nil) -> CursorSessionTailer {
        CursorSessionTailer(source: source, cursor: cursor, clock: { observed })
    }

    @Test("a cold poll returns the conversation, and the next one returns nothing")
    func coldPoll() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let tailer = tailer(source(store: store))

        let first = try tailer.poll()
        #expect(histogram(first)["userPrompt"] == 1)
        #expect(histogram(first)["toolCallStarted"] == 1)
        #expect(try tailer.poll().isEmpty)
    }

    @Test("a poll after a new turn returns only the new turn")
    func incrementalPoll() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let tailer = tailer(source(store: store))
        _ = try tailer.poll()

        try appendTurnTwo(store)
        let second = try tailer.poll()
        #expect(previews(second) == ["now make the walk incremental", "Cached the visit set."])
    }

    @Test("a persisted cursor round-trips and resumes without re-emitting")
    func resume() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let source = source(store: store)

        let first = tailer(source)
        _ = try first.poll()

        let encoded = try JSONEncoder().encode(first.cursor)
        let restored = try JSONDecoder().decode(SourceCursor.self, from: encoded)
        #expect(restored == first.cursor)
        guard case let .composite(parts) = restored,
              case let .blobHead(head)? = parts[store.path] else {
            Issue.record("expected a composite cursor with a blob head")
            return
        }
        #expect(head == "\(Ids.root1.hex)|\(Ids.reply1.anchor)")

        try appendTurnTwo(store)
        // A fresh tailer, as a relaunched host would build: no in-memory visit
        // set, only the persisted anchor.
        let resumed = tailer(source, cursor: restored)
        let events = try resumed.poll()
        #expect(previews(events) == ["now make the walk incremental", "Cached the visit set."])
    }

    @Test("a cursor whose root is current returns nothing without walking")
    func resumeWithNothingNew() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let source = source(store: store)
        let first = tailer(source)
        _ = try first.poll()

        let resumed = tailer(source, cursor: first.cursor)
        #expect(try resumed.poll().isEmpty)
        #expect(resumed.cursor == first.cursor)
    }

    @Test("a cursor of the wrong shape re-seeds instead of failing")
    func foreignCursor() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let resumed = tailer(source(store: store), cursor: .rowID(17))
        #expect(try resumed.poll().count > 0)
    }

    @Test("a seed reads the tail of the conversation, not the whole of it")
    func seed() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let tailer = tailer(source(store: store))

        // 4 KiB buys two messages: the tool result and the reply.
        #expect(CursorSessionTailer.seedMessages(forBytes: 4096) == 2)
        let events = try tailer.seedFromTail(maxBytes: 4096)
        #expect(histogram(events)["userPrompt"] == nil)
        #expect(previews(events) == ["The suite is green."])
        // The seed skipped the head of the conversation on purpose; it must
        // not come back.
        #expect(try tailer.poll().isEmpty)
    }

    @Test("the thin transcript owns the turn skeleton and the store owns the body")
    func composite() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let transcript = try CursorFixture.writeThinTranscript(
            home: tree.url,
            slug: projectSlug,
            agentID: agentID,
            lines: [
                CursorFixture.transcriptUserLine("add a test for the reducer"),
                CursorFixture.transcriptAssistantLine("The suite is green."),
                CursorFixture.transcriptTurnEnded()
            ]
        )
        let tailer = tailer(source(store: store, transcript: transcript.path))
        let events = try tailer.poll()
        let counts = histogram(events)

        // Exactly one prompt, from the transcript — the reducer counts a turn
        // per prompt, and two sources reporting it would double every turn.
        #expect(counts["userPrompt"] == 1)
        #expect(counts["textBody.user"] == 1)
        #expect(counts["turnEnded.complete"] == 1)
        #expect(counts["assistantText"] == 1)
        #expect(counts["toolCallStarted"] == 1)

        // The transcript closes the batch, so the reducer lands on the state
        // the session is actually in.
        #expect(label(try #require(events.last).kind) == "turnEnded.complete")
        #expect(events.map(\.sequence) == Array(1...Int64(events.count)))

        guard case let .composite(parts) = tailer.cursor else {
            Issue.record("expected a composite cursor")
            return
        }
        #expect(parts.keys.sorted() == [store.path, transcript.path].sorted())
    }

    @Test("every store event points back at the database it came from")
    func rawReferences() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let events = try tailer(source(store: store)).poll()
        #expect(events.allSatisfy { $0.raw?.path == store.path })
        #expect(events.allSatisfy { $0.raw?.byteOffset == nil && $0.raw?.rowID == nil })
    }
}

// MARK: - The cursor codec

@Suite("CursorStoreCursor")
struct CursorStoreCursorTests {
    @Test("the two halves round-trip through the string form")
    func roundTrip() throws {
        let cursor = CursorStoreCursor(root: Ids.root1.hex, anchor: Ids.reply1.anchor)
        #expect(CursorStoreCursor.decode(cursor.encoded) == cursor)

        let rootOnly = CursorStoreCursor(root: Ids.root1.hex, anchor: nil)
        #expect(CursorStoreCursor.decode(rootOnly.encoded) == rootOnly)
        #expect(CursorStoreCursor.decode("") == nil)
        #expect(CursorStoreCursor.decode("|orphan") == nil)
    }

    @Test("a cursor of another shape is discarded rather than rejected")
    func foreignShapes() {
        #expect(CursorStoreCursor.extract(from: .rowID(3), path: "/store.db") == nil)
        #expect(CursorStoreCursor.extract(from: .byteOffset(inode: 1, offset: 2), path: "/store.db") == nil)
        #expect(CursorStoreCursor.extract(from: nil, path: "/store.db") == nil)
        #expect(CursorStoreCursor.extract(
            from: .composite(["/store.db": .blobHead("abc|def.0")]), path: "/store.db"
        ) == CursorStoreCursor(root: "abc", anchor: "def.0"))
    }
}

// MARK: - Paths

@Suite("CursorPaths")
struct CursorPathsTests {
    @Test("a cwd slugs the way Cursor names a project directory")
    func slugs() {
        #expect(CursorPaths.slug(forCWD: "/Users/example/code/reducer") == "Users-example-code-reducer")
        #expect(CursorPaths.slug(forCWD: "/private/tmp/x") == "private-tmp-x")
        #expect(CursorPaths.slug(forCWD: "/Users/example/code/reducer/") == "Users-example-code-reducer")
    }

    @Test("decoding a slug is a guess the file system narrows")
    func decode() {
        let tree = TemporaryTree()
        let nested = tree.url.appendingPathComponent("agent-session-kit/Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let slug = CursorPaths.slug(forCWD: nested.path)
        // Without the file system, `agent-session-kit` reads as three
        // components; with it, the real directory wins.
        #expect(CursorPaths.cwd(forSlug: slug) == nested.path)
        #expect(CursorPaths.cwd(forSlug: "does-not-exist") == "/does/not/exist")
        #expect(CursorPaths.cwd(forSlug: "") == nil)
    }

    @Test("a transcript is found by cwd, and by scan when the cwd is wrong")
    func transcriptLookup() throws {
        let tree = TemporaryTree()
        let path = try CursorFixture.writeThinTranscript(
            home: tree.url, slug: projectSlug, agentID: agentID, lines: []
        ).path

        #expect(CursorPaths.findThinTranscript(home: tree.path, agentID: agentID, cwd: projectCWD) == path)
        #expect(CursorPaths.findThinTranscript(home: tree.path, agentID: agentID, cwd: "/elsewhere") == path)
        #expect(CursorPaths.findThinTranscript(home: tree.path, agentID: otherAgentID, cwd: nil) == nil)
    }

    @Test("a worker pid file is read, and anything that is not a pid is not one")
    func workerPIDs() throws {
        let tree = TemporaryTree()
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: 4711)
        let files = CursorPaths.workerPIDFiles(home: tree.path)
        #expect(files.count == 1)
        #expect(CursorPaths.workerPID(atPath: try #require(files.first).path) == 4711)
        #expect(CursorPaths.workerPID(atPath: "/nonexistent.pid") == nil)

        tree.write("not a pid", to: "Library/Application Support/Cursor/User/globalStorage/"
            + "anysphere.cursor-agent-worker/cursor-agent-worker-w2.pid")
        #expect(CursorPaths.workerPID(atPath: CursorPaths.workerRoot(home: tree.path)
            .appendingPathComponent("cursor-agent-worker-w2.pid").path) == nil)
    }
}

// MARK: - The worker probe

@Suite("CursorWorkerProbe")
struct CursorWorkerProbeTests {
    @Test("this process is alive and pid zero is not")
    func processLiveness() {
        #expect(CursorWorkerProbe.isProcessAlive(pid: getpid()))
        #expect(!CursorWorkerProbe.isProcessAlive(pid: 0))
        #expect(!CursorWorkerProbe.isProcessAlive(pid: -1))
    }

    @Test("a socket nobody is listening on is told apart from one somebody is")
    func socketLiveness() throws {
        // Short path on purpose: `sun_path` is 104 bytes and a temporary
        // directory plus a project slug does not fit in it.
        let path = "/tmp/ask-cursor-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A plain file where a socket should be: what a crashed worker leaves.
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(!CursorWorkerProbe.socketAccepts(path: path))
        #expect(!CursorWorkerProbe.socketAccepts(path: "/tmp/ask-cursor-missing.sock"))

        try? FileManager.default.removeItem(atPath: path)
        let listener = try #require(UnixSocketListener(path: path))
        defer { listener.close() }
        #expect(CursorWorkerProbe.socketAccepts(path: path))
    }
}

/// A listening `AF_UNIX` socket, for the one probe branch that needs a real
/// one on the other end.
private final class UnixSocketListener {
    private let descriptor: Int32
    private let path: String

    init?(path: String) {
        self.path = path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
    }

    func close() {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - The adapter

@Suite("CursorLiveAdapter")
struct CursorLiveAdapterTests {
    private let adapter = CursorLiveAdapter(clock: { Date() })

    @Test("the watch roots are the three directories Cursor writes into")
    func watchRoots() {
        let roots = adapter.watchRoots(home: "/Users/example").map(\.path)
        #expect(roots == [
            "/Users/example/.cursor/chats",
            "/Users/example/.cursor/projects",
            "/Users/example/Library/Application Support/Cursor/User/globalStorage/"
                + "anysphere.cursor-agent-worker"
        ])
    }

    @Test("discovery seeds the identity a CLI session arrives with")
    func discoverCLISession() async throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeAgentMeta(home: tree.url, agentID: agentID, cwd: projectCWD)
        let transcript = try CursorFixture.writeThinTranscript(
            home: tree.url, slug: projectSlug, agentID: agentID,
            lines: [CursorFixture.transcriptTurnEnded()]
        )

        let sources = try await adapter.discover(home: tree.path, activeSince: .distantPast)
        #expect(sources.count == 1)
        let source = try #require(sources.first)

        #expect(source.key == session)
        #expect(canonical(source.primaryPath) == canonical(store.path))
        #expect(source.auxiliaryPaths.map(canonical) == [canonical(transcript.path)])
        #expect(source.seedIdentity.cwd == projectCWD)
        #expect(source.seedIdentity.title == "Wire up the reducer")
        #expect(source.seedIdentity.variant == "agent")
        #expect(source.seedIdentity.entrypoint == "cursor-agent")
        #expect(canonical(source.seedIdentity.sourcePath) == canonical(store.path))
        // Nothing else is guessed at: the model only appears once a turn
        // named one, and the tailer is what reads it.
        #expect(source.seedIdentity.model == nil)
    }

    @Test("an agent with no thin transcript was started in the IDE")
    func discoverIDESession() async throws {
        let tree = TemporaryTree()
        try writeTurnOne(tree)
        try CursorFixture.writeAgentMeta(home: tree.url, agentID: agentID, cwd: projectCWD)

        let source = try #require(
            try await adapter.discover(home: tree.path, activeSince: .distantPast).first
        )
        #expect(source.auxiliaryPaths.isEmpty)
        #expect(source.seedIdentity.entrypoint == "cursor-ide")
    }

    @Test("a store untouched since the cutoff is not discovered")
    func cutoff() async throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeAgentMeta(
            home: tree.url, agentID: agentID, cwd: projectCWD,
            updatedAt: Date().addingTimeInterval(-7200)
        )
        CursorFixture.backdate(store.path, by: 7200)

        #expect(try await adapter.discover(home: tree.path, activeSince: Date().addingTimeInterval(-600))
            .isEmpty)
        #expect(try await adapter.discover(home: tree.path, activeSince: .distantPast).count == 1)
    }

    @Test("a live cursor-agent worker for the project overrides the cutoff")
    func liveWorkerOverridesTheCutoff() async throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeAgentMeta(
            home: tree.url, agentID: agentID, cwd: projectCWD,
            updatedAt: Date().addingTimeInterval(-7200)
        )
        CursorFixture.backdate(store.path, by: 7200)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: getpid())
        try CursorFixture.writeWorkerSocketFile(home: tree.url, slug: projectSlug)

        let sources = try await adapter.discover(
            home: tree.path, activeSince: Date().addingTimeInterval(-600)
        )
        #expect(sources.map(\.key) == [session])
    }

    @Test("a store whose card names another agent is skipped")
    func idDisagreement() async throws {
        let tree = TemporaryTree()
        try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: CursorFixture.card(agentID: otherAgentID, root: Ids.root1),
            blobs: turnOneBlobs
        )
        #expect(try await adapter.discover(home: tree.path, activeSince: .distantPast).isEmpty)
    }

    @Test("a store whose card cannot be read is still a session")
    func unreadableCard() async throws {
        let tree = TemporaryTree()
        try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: [:],
            metaValue: "not hex at all",
            blobs: []
        )
        let source = try #require(
            try await adapter.discover(home: tree.path, activeSince: .distantPast).first
        )
        #expect(source.key == session)
        #expect(source.seedIdentity.title == nil)
    }

    @Test("a missing chats directory discovers nothing rather than throwing")
    func emptyHome() async throws {
        let tree = TemporaryTree()
        #expect(try await adapter.discover(home: tree.path, activeSince: .distantPast).isEmpty)
    }

    @Test("the tailer the adapter builds is the composite one")
    func makeTailer() async throws {
        let tree = TemporaryTree()
        try writeTurnOne(tree)
        try CursorFixture.writeAgentMeta(home: tree.url, agentID: agentID, cwd: projectCWD)
        let source = try #require(
            try await adapter.discover(home: tree.path, activeSince: .distantPast).first
        )
        let tailer = try adapter.makeTailer(source, cursor: nil)
        #expect(tailer is CursorSessionTailer)
        #expect(try await tailer.poll().count > 0)
    }
}

// MARK: - Liveness

@Suite("CursorLiveAdapter liveness")
struct CursorLivenessTests {
    private func identity(store: URL, cwd: String? = projectCWD) -> SessionIdentity {
        var identity = SessionIdentity(key: session, sourcePath: store.path)
        identity.cwd = cwd
        return identity
    }

    private func record(pid: pid_t, cwd: String? = nil) -> ProcessRecord {
        ProcessRecord(
            pid: pid,
            ppid: 1,
            startTime: Date().addingTimeInterval(-60),
            executablePath: "/usr/local/bin/cursor-agent",
            argv: ["cursor-agent", "--api-key", "crsr_0123456789abcdef"],
            cwd: cwd
        )
    }

    @Test("a worker whose environment names this agent is proof")
    func environmentMatch() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: getpid())
        let table = FakeProcessTable(
            records: [record(pid: getpid())],
            environments: [getpid(): [CursorLiveAdapter.chatIDVariable: agentID]]
        )

        let hint = CursorLiveAdapter().probeLiveness(identity(store: store), table: table, home: tree.path)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == getpid())
        #expect(hint.evidence.contains(CursorLiveAdapter.chatIDVariable))
    }

    @Test("a worker running in the session's directory is the weaker match")
    func workingDirectoryMatch() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: getpid())
        let table = FakeProcessTable(records: [record(pid: getpid(), cwd: projectCWD)])

        let hint = CursorLiveAdapter().probeLiveness(identity(store: store), table: table, home: tree.path)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == getpid())
    }

    @Test("a worker for another agent is not this one's evidence")
    func otherAgentsWorker() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        CursorFixture.backdate(store.path, by: 3600)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: getpid())
        let table = FakeProcessTable(
            records: [record(pid: getpid(), cwd: "/Users/example/code/other")],
            environments: [getpid(): [CursorLiveAdapter.chatIDVariable: otherAgentID]]
        )

        let hint = CursorLiveAdapter().probeLiveness(identity(store: store), table: table, home: tree.path)
        #expect(hint.verdict == .dead)
    }

    @Test("a pid file whose process is gone is not evidence of death")
    func stalePIDFile() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: 999_999)

        // Nothing in the table, but the store was just written.
        let hint = CursorLiveAdapter().probeLiveness(
            identity(store: store), table: FakeProcessTable(records: []), home: tree.path
        )
        #expect(hint.verdict == .alive)
        #expect(hint.evidence.contains("WAL"))
    }

    @Test("a recently written store is alive on its own")
    func recentWrite() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        let hint = CursorLiveAdapter().probeLiveness(
            identity(store: store), table: FakeProcessTable(records: []), home: tree.path
        )
        #expect(hint.verdict == .alive)
    }

    @Test("a long-quiet store with no worker is dead")
    func quietStore() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        CursorFixture.backdate(store.path, by: 3600)
        let hint = CursorLiveAdapter().probeLiveness(
            identity(store: store), table: FakeProcessTable(records: []), home: tree.path
        )
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("60 min"))
    }

    @Test("a store between the two windows is honest about not knowing")
    func inBetween() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        CursorFixture.backdate(store.path, by: 120)
        let hint = CursorLiveAdapter().probeLiveness(
            identity(store: store), table: FakeProcessTable(records: []), home: tree.path
        )
        #expect(hint.verdict == .unknown)
    }

    @Test("a store that cannot be stat'd at all is unknown, never dead")
    func missingStore() {
        let tree = TemporaryTree()
        var identity = SessionIdentity(
            key: session, sourcePath: tree.file("gone/store.db").path
        )
        identity.cwd = projectCWD
        let hint = CursorLiveAdapter().probeLiveness(
            identity, table: FakeProcessTable(records: []), home: tree.path
        )
        #expect(hint.verdict == .unknown)
    }
}

// MARK: - Privacy

@Suite("Cursor privacy")
struct CursorPrivacyTests {
    @Test("nothing a probe says carries an argv value or a home path")
    func evidenceIsSanitized() throws {
        let tree = TemporaryTree()
        let store = try writeTurnOne(tree)
        try CursorFixture.writeWorkerPID(home: tree.url, workerID: "w1", pid: getpid())
        let table = FakeProcessTable(
            records: [ProcessRecord(
                pid: getpid(),
                ppid: 1,
                startTime: Date(),
                executablePath: "/usr/local/bin/cursor-agent",
                argv: ["cursor-agent", "--api-key", "crsr_0123456789abcdef"],
                cwd: projectCWD
            )],
            environments: [getpid(): [
                CursorLiveAdapter.chatIDVariable: agentID,
                "CURSOR_API_KEY": "crsr_0123456789abcdef"
            ]]
        )

        var identity = SessionIdentity(key: session, sourcePath: store.path)
        identity.cwd = projectCWD
        let hint = CursorLiveAdapter().probeLiveness(identity, table: table, home: tree.path)

        #expect(!hint.evidence.contains("crsr_"))
        #expect(!hint.evidence.contains("/Users/"))
        #expect(!hint.evidence.contains(tree.path))
    }

    @Test("a tool call's target never carries a file body")
    func targetsAreBounded() {
        let body = String(repeating: "x", count: 100_000)
        let resolved = CursorToolMapping.resolve(
            name: "edit_file", arguments: CursorMessage.arguments([
                "target_file": "Sources/App.swift", "code_edit": body
            ])
        )
        #expect(resolved.target == "Sources/App.swift")
        #expect((resolved.target?.count ?? 0) <= CursorToolMapping.targetLimit)
    }

    @Test("a text body is capped at the event model's limit")
    func bodiesAreBounded() throws {
        let tree = TemporaryTree()
        let long = String(repeating: "词", count: 40_000)
        let store = try CursorFixture.writeStore(
            home: tree.url,
            agentID: agentID,
            card: CursorFixture.card(agentID: agentID, root: Ids.root1),
            blobs: [
                CursorFixture.Blob(id: Ids.root1, data: CursorFixture.node(references: [Ids.reply1])),
                CursorFixture.Blob(id: Ids.reply1, message: CursorFixture.assistantMessage(
                    [CursorFixture.textPart(long)]
                ))
            ]
        )
        let text = try #require(bodies(storeEvents(store)).first)
        #expect(text.utf8.count <= AgentEventKind.textBodyLimit)
        // Cut on a character boundary, never mid-scalar.
        #expect(!text.hasSuffix("\u{FFFD}"))
    }
}
