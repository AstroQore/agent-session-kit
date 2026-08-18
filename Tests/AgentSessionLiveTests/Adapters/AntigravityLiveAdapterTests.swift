import AgentSessionKit
import Foundation
import Testing

@testable import AgentSessionLive

// MARK: - Shared fixtures

/// A fixed instant every AntiGravity fixture builds its timeline from.
private let base: UInt64 = 1_778_307_200

private let conversationA = "11111111-2222-3333-4444-555555555555"
private let conversationB = "22222222-3333-4444-5555-666666666666"
private let conversationC = "33333333-4444-5555-6666-777777777777"

private let sessionA = SessionKey(harness: .antigravity, sessionID: conversationA)

/// The conversation every tailer test walks: a prompt, a reply still being
/// generated, a command still running, a finished edit, a question waiting on
/// a person, and a sub-agent invocation.
private func canonicalSteps() -> [AntigravityStepFixture] {
    [
        AntigravityStepFixture(
            idx: 0, type: .userInput, status: .done,
            text: "Add a regression test for the conversation tailer.",
            startedAt: base, endedAt: base,
            source: .userExplicit,
            transitions: [.init(status: .done, at: base)],
            noise: [
                "cccccccc-1111-2222-3333-444444444444",
                "/Users/example/code/demo/Sources/App/Main.swift",
                "dGhpc2lzYmFzZTY0bm9pc2VBQkNERUZHSA==",
                "toolSummary"
            ]
        ),
        AntigravityStepFixture(
            idx: 1, type: .plannerResponse, status: .generating,
            startedAt: base + 1,
            source: .model,
            transitions: [.init(status: .generating, at: base + 1)]
        ),
        AntigravityStepFixture(
            idx: 2, type: .runCommand, status: .running,
            toolCall: .init(
                callID: "tooluse_1", name: "run_command",
                argsJSON: #"{"CommandLine":"swift test --filter TailerTests"}"#),
            startedAt: base + 2,
            source: .model,
            transitions: [
                .init(status: .pending, at: base + 2), .init(status: .running, at: base + 2)
            ]
        ),
        AntigravityStepFixture(
            idx: 3, type: .codeAction, status: .done,
            toolCall: .init(
                callID: "tooluse_2", name: "code_action",
                argsJSON: #"{"TargetFile":"/Users/example/code/demo/Tests/TailerTests.swift"}"#),
            startedAt: base + 3, endedAt: base + 4,
            source: .model,
            transitions: [.init(status: .running, at: base + 3), .init(status: .done, at: base + 4)]
        ),
        AntigravityStepFixture(
            idx: 4, type: .askQuestion, status: .waiting,
            text: "Should the fixture cover the rotation case too?",
            startedAt: base + 5,
            source: .model
        ),
        AntigravityStepFixture(
            idx: 5, type: .invokeSubagent, status: .done, hasSubtrajectory: true,
            toolCall: .init(callID: "tooluse_3", name: "invoke_subagent"),
            startedAt: base + 6, endedAt: base + 7,
            source: .model
        )
    ]
}

private func tailer(
    over url: URL,
    key: SessionKey = sessionA,
    cursor: SourceCursor? = nil,
    registry: AntigravityConversationRegistry = AntigravityConversationRegistry()
) -> AntigravityConversationTailer {
    AntigravityConversationTailer(
        source: SessionSource(
            key: key,
            primaryPath: url.path,
            seedIdentity: SessionIdentity(key: key, sourcePath: url.path)),
        cursor: cursor,
        registry: registry
    )
}

/// Every string an event carries, so a privacy sweep can look at all of them.
private func strings(in kind: AgentEventKind) -> [String] {
    switch kind {
    case let .userPrompt(preview): [preview]
    case let .assistantText(preview): [preview]
    case let .toolCallStarted(id, name, _, target): [id, name, target].compactMap { $0 }
    case let .toolCallFinished(id, _): [id]
    case let .permissionRequested(id, tool): [id, tool].compactMap { $0 }
    case let .permissionResolved(id, _): [id]
    case let .note(text): [text]
    case let .textBody(_, text, callID): [text, callID].compactMap { $0 }
    case let .subagentStarted(child, type, toolUse): [child.sessionID, type, toolUse].compactMap { $0 }
    default: []
    }
}

// MARK: - The enum tables

@Suite("AntiGravity step enums")
struct AntigravityStepEnumTests {
    @Test("the step table is the descriptor's, complete and without collisions")
    func stepTable() {
        #expect(AntigravityStepType.allCases.count == 118)
        #expect(Set(AntigravityStepType.allCases.map(\.rawValue)).count == 118)
        // Gaps in the descriptor stay gaps: 11, 12, 16 and friends do not exist.
        #expect(AntigravityStepType(rawValue: 11) == nil)
        #expect(AntigravityStepType(rawValue: 115) == nil)
        #expect(AntigravityStepType.label(rawValue: 9_999) == "step_9999")
    }

    @Test("a tool's number, name, and kind agree with the descriptor")
    func toolKinds() {
        #expect(AntigravityStepType(rawValue: 21) == .runCommand)
        #expect(AntigravityStepType.runCommand.label == "run_command")
        #expect(AntigravityStepType.runCommand.toolKind == .shell)
        #expect(AntigravityStepType.shellExec.toolKind == .shell)
        #expect(AntigravityStepType.readTerminal.toolKind == .shell)
        #expect(AntigravityStepType.viewFile.toolKind == .fileRead)
        #expect(AntigravityStepType.readNotebook.toolKind == .fileRead)
        #expect(AntigravityStepType.codeAction.toolKind == .fileWrite)
        #expect(AntigravityStepType.writeBlob.toolKind == .fileWrite)
        #expect(AntigravityStepType.grepSearch.toolKind == .search)
        #expect(AntigravityStepType.toolSearch.toolKind == .search)
        #expect(AntigravityStepType(rawValue: 33) == .searchWeb)
        #expect(AntigravityStepType.searchWeb.toolKind == .web)
        #expect(AntigravityStepType.browserClickElement.toolKind == .web)
        #expect(AntigravityStepType.mcpTool.toolKind == .mcp)
        #expect(AntigravityStepType(rawValue: 127) == .invokeSubagent)
        #expect(AntigravityStepType.invokeSubagent.toolKind == .subagent)
        #expect(AntigravityStepType.planInput.toolKind == .plan)
        // A tool the buckets do not describe is `other`, never a guess.
        #expect(AntigravityStepType.generateImage.toolKind == .other)
    }

    @Test("rows that are said rather than called are not tools")
    func nonTools() {
        for type in [
            AntigravityStepType.userInput, .plannerResponse, .askQuestion, .checkpoint,
            .conversationHistory, .errorMessage, .notifyUser, .systemMessage, .finish
        ] {
            #expect(type.toolKind == nil, "\(type.label) should not be a tool")
            #expect(type.isTool == false)
        }
    }

    @Test("status 9 is WAITING, and open and terminal are not a guess")
    func statuses() {
        #expect(AntigravityStepStatus(rawValue: 9) == .waiting)
        #expect(AntigravityStepStatus(rawValue: 10) == nil)
        #expect(AntigravityStepStatus.waiting.isOpen)
        #expect(AntigravityStepStatus.running.isOpen)
        #expect(AntigravityStepStatus.generating.isOpen)
        #expect(AntigravityStepStatus.queued.isOpen)
        #expect(AntigravityStepStatus.pending.isOpen)
        #expect(AntigravityStepStatus.done.isTerminal)
        #expect(AntigravityStepStatus.canceled.isTerminal)
        #expect(AntigravityStepStatus.interrupted.isTerminal)
        // A status nothing named must not leave a call open forever.
        #expect(AntigravityStepStatus.unspecified.isTerminal)
        #expect(AntigravityStepStatus.error.isFailure)
    }

    @Test("trajectory and step sources match the descriptor")
    func sources() {
        #expect(AntigravityTrajectorySource(rawValue: 17) == .cli)
        #expect(AntigravityTrajectorySource(rawValue: 16) == .subagent)
        #expect(AntigravityTrajectorySource(rawValue: 12) == .interactiveCascade)
        #expect(AntigravityTrajectorySource(rawValue: 15) == .sdk)
        #expect(AntigravityTrajectorySource(rawValue: 19) == .agentAPI)
        #expect(AntigravityTrajectoryType(rawValue: 4) == .cascade)
        #expect(AntigravityTrajectoryType(rawValue: 17) == .interactiveCascade)
        #expect(AntigravityStepSource(rawValue: 4) == .userExplicit)
        #expect(AntigravityStepSource(rawValue: 1) == nil)
    }
}

// MARK: - The payload decoder

@Suite("AntigravityStepPayload")
struct AntigravityStepPayloadTests {
    @Test("everything the encoder writes comes back out")
    func roundTrip() throws {
        let step = AntigravityStepFixture(
            idx: 7, type: .runCommand, status: .running,
            text: "Running the regression suite before the change lands.",
            toolCall: .init(
                callID: "tooluse_9", name: "run_command",
                argsJSON: #"{"CommandLine":"swift build"}"#),
            startedAt: base, endedAt: base + 12,
            source: .model,
            transitions: [
                .init(status: .pending, at: base),
                .init(status: .running, at: base + 1),
                .init(status: .done, at: base + 12)
            ],
            promptTokens: 4_211,
            requestID: "req-0001"
        )
        let payload = try #require(AntigravityStepPayload.decode(step.payload))

        #expect(payload.stepType == .runCommand)
        #expect(payload.status == .running)
        #expect(payload.source == .model)
        #expect(payload.startedAt?.timeIntervalSince1970 == Double(base))
        #expect(payload.endedAt?.timeIntervalSince1970 == Double(base + 12))
        #expect(payload.toolCall?.callID == "tooluse_9")
        #expect(payload.toolCall?.name == "run_command")
        #expect(payload.toolCall?.argsJSON == #"{"CommandLine":"swift build"}"#)
        #expect(payload.promptTokens == 4_211)
        #expect(payload.requestID == "req-0001")
        #expect(payload.trajectoryID == AntigravityDatabaseFixture.trajectoryID)
        #expect(payload.cascadeID == AntigravityDatabaseFixture.cascadeID)
        #expect(payload.transitions.map(\.status) == [.pending, .running, .done])
        #expect(payload.transitions.last?.at?.timeIntervalSince1970 == Double(base + 12))
        #expect(payload.latestTransition?.status == .done)
        #expect(payload.textPreview == "Running the regression suite before the change lands.")
    }

    @Test("the payload's own step type is read, not assumed from the column")
    func payloadTypeIsIndependent() throws {
        let step = AntigravityStepFixture(
            idx: 0, type: .userInput, status: .done, payloadStepTypeOverride: .plannerResponse)
        let payload = try #require(AntigravityStepPayload.decode(step.payload))
        #expect(payload.stepType == .plannerResponse)
    }

    @Test("a prompt is found where USER_INPUT puts it, not where a reply does")
    func promptField() throws {
        let step = AntigravityStepFixture(
            idx: 0, type: .userInput, status: .done,
            text: "Summarise what changed in the tailer this week.")
        let payload = try #require(AntigravityStepPayload.decode(step.payload))
        #expect(payload.textPreview == "Summarise what changed in the tailer this week.")
    }

    @Test("identifiers around the text are not mistaken for it")
    func proseFilter() {
        #expect(AntigravityStepText.readsAsText("Reading the input JSON file"))
        #expect(AntigravityStepText.readsAsText("翻译项目启动与核心术语确认"))
        #expect(AntigravityStepText.readsAsText("已经完成了"))

        #expect(AntigravityStepText.readsAsText("short") == false)
        #expect(AntigravityStepText.readsAsText("toolSummary") == false)
        #expect(AntigravityStepText.readsAsText("cccccccc-1111-2222-3333-444444444444") == false)
        #expect(AntigravityStepText.readsAsText("/Users/example/code/demo/Main.swift") == false)
        #expect(AntigravityStepText.readsAsText("dGhpc2lzYmFzZTY0bm9pc2VBQkNERUZHSA==") == false)
        #expect(AntigravityStepText.readsAsText("-3750763034362895579P") == false)
    }

    @Test("noise beside the text does not win")
    func noiseDoesNotWin() throws {
        let step = canonicalSteps()[0]
        let payload = try #require(AntigravityStepPayload.decode(step.payload))
        #expect(payload.textPreview == "Add a regression test for the conversation tailer.")
    }

    @Test("a blob that is not a payload yields nothing rather than throwing")
    func garbage() {
        #expect(AntigravityStepPayload.decode(Data()) == nil)
        // A run of continuation bytes: a varint that never terminates.
        #expect(AntigravityStepPayload.decode(Data(repeating: 0xFF, count: 32)) == nil)
        // Truncated: a valid tag whose length runs past the end.
        let truncated = Data(AntigravityProto.tag(5, 2) + AntigravityProto.varint(200))
        let payload = AntigravityStepPayload.decode(truncated)
        #expect(payload?.toolCall == nil)
    }

    @Test("the zero timestamp AntiGravity writes for never is not a date")
    func zeroTimestamp() throws {
        let step = AntigravityStepFixture(
            idx: 0, type: .finish, status: .done, startedAt: 0, endedAt: base)
        let payload = try #require(AntigravityStepPayload.decode(step.payload))
        #expect(payload.startedAt == nil)
        #expect(payload.endedAt?.timeIntervalSince1970 == Double(base))
    }
}

// MARK: - The readers

@Suite("AntigravityConversationReader")
struct AntigravityConversationReaderTests {
    @Test("steps come back in order, with their payloads decoded")
    func readsSteps() throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let reader = AntigravityConversationReader(databaseURL: url)

        let rows = try #require(reader.steps())
        #expect(rows.map(\.idx) == [0, 1, 2, 3, 4, 5])
        #expect(rows.map(\.stepType) == [
            .userInput, .plannerResponse, .runCommand, .codeAction, .askQuestion, .invokeSubagent
        ])
        #expect(rows.map(\.status) == [.done, .generating, .running, .done, .waiting, .done])
        #expect(rows[5].hasSubtrajectory)
        #expect(rows[2].toolName == "run_command")
        #expect(rows[2].toolKind == .shell)
        #expect(rows[0].toolKind == nil)
        #expect(reader.stepCount() == 6)
        #expect(reader.lastStepIndex() == 5)
        #expect(reader.conversationID == conversationA)
        #expect(reader.parentReferences().isEmpty)
    }

    @Test("a window starts where it is asked to and stops where it is capped")
    func window() throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let reader = AntigravityConversationReader(databaseURL: url)
        #expect(reader.steps(fromIndex: 3)?.map(\.idx) == [3, 4, 5])
        #expect(reader.steps(fromIndex: 0, limit: 2)?.map(\.idx) == [0, 1])
        #expect(reader.steps(fromIndex: 99)?.isEmpty == true)
        #expect(reader.steps(fromIndex: 0, limit: 0)?.isEmpty == true)
    }

    @Test("payloads can be left on disk when only the statuses are wanted")
    func withoutPayloads() throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let rows = try #require(
            AntigravityConversationReader(databaseURL: url)
                .steps(fromIndex: 0, decodePayloads: false))
        #expect(rows.allSatisfy { $0.payload == nil })
        #expect(rows.map(\.status) == [.done, .generating, .running, .done, .waiting, .done])
        // A row with no payload still names itself from its column.
        #expect(rows[2].toolName == "run_command")
    }

    @Test("trajectory_meta names the surface that opened the conversation")
    func trajectoryMeta() throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps(), source: .subagent)
        let meta = try #require(AntigravityConversationReader(databaseURL: url).trajectoryMeta())
        #expect(meta.source == .subagent)
        #expect(meta.trajectoryType == .cascade)
        #expect(meta.trajectoryID == AntigravityDatabaseFixture.trajectoryID)
        #expect(meta.cascadeID == AntigravityDatabaseFixture.cascadeID)
    }

    @Test("a live write-ahead log is read, not worked around")
    func walMode() throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps(), walMode: true)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(AntigravityConversationReader(databaseURL: url).stepCount() == 6)
    }

    @Test("a database that is not there answers nil, not a crash")
    func missing() {
        let reader = AntigravityConversationReader(
            databaseURL: URL(fileURLWithPath: "/nonexistent/conversations/none.db"))
        #expect(reader.steps() == nil)
        #expect(reader.stepCount() == nil)
        #expect(reader.trajectoryMeta() == nil)
        #expect(reader.parentReferences().isEmpty)
    }
}

@Suite("AntigravitySummariesReader")
struct AntigravitySummariesReaderTests {
    @Test("a row's title, workspace, parent, and flags all come through")
    func readsRows() throws {
        let home = AntigravityHome()
        try home.writeSummaries([
            .init(
                id: conversationA, title: "", preview: "### Nightly triage",
                stepCount: 6, workspaces: #"["file:///Users/example/agy%20misc"]"#),
            .init(
                id: conversationB, title: "Child run", parent: conversationA,
                nestingDepth: 1, notFullyIdle: true),
            .init(id: conversationC, title: "Stopped", killed: true)
        ])
        let rows = AntigravitySummariesReader(databaseURL: home.summariesURL).summaries()
        let byID = Dictionary(rows.map { ($0.conversationID, $0) }, uniquingKeysWith: { a, _ in a })

        // `title` is empty on every build seen so far; the label lands in
        // `preview`, as a markdown heading.
        #expect(byID[conversationA]?.title == "Nightly triage")
        #expect(byID[conversationA]?.stepCount == 6)
        #expect(byID[conversationA]?.workspacePath == "/Users/example/agy misc")
        #expect(byID[conversationA]?.lastModified?.timeIntervalSince1970 ?? 0 > 0)
        #expect(byID[conversationB]?.parentConversationID == conversationA)
        // An empty `parent_conversation_id` is "no parent", not a parent named "".
        #expect(byID[conversationA]?.parentConversationID == nil)
        #expect(byID[conversationB]?.nestingDepth == 1)
        #expect(byID[conversationB]?.notFullyIdle == true)
        #expect(byID[conversationC]?.killed == true)
        #expect(byID[conversationA]?.agentName == "agy")
    }

    @Test("the cutoff keeps a busy conversation however old its timestamp is")
    func cutoff() throws {
        let home = AntigravityHome()
        try home.writeSummaries([
            .init(id: conversationA, title: "Old and quiet",
                  lastModified: "2020-01-01 00:00:00.000000+00:00"),
            .init(id: conversationB, title: "Old and busy",
                  lastModified: "2020-01-01 00:00:00.000000+00:00", notFullyIdle: true)
        ])
        let reader = AntigravitySummariesReader(databaseURL: home.summariesURL)
        #expect(reader.summaries().count == 2)
        let recent = reader.summaries(modifiedSince: Date(timeIntervalSince1970: Double(base)))
        #expect(recent.map(\.conversationID) == [conversationB])
    }

    @Test("a store that is not there is empty, not an error")
    func missing() {
        let home = AntigravityHome()
        #expect(AntigravitySummariesReader(databaseURL: home.summariesURL).summaries().isEmpty)
    }

    @Test("the column shapes AntiGravity actually writes")
    func columnShapes() {
        #expect(AntigravitySummariesReader.label("", "### Heading") == "Heading")
        #expect(AntigravitySummariesReader.label("Real title", "preview") == "Real title")
        #expect(AntigravitySummariesReader.label("", "") == nil)
        #expect(AntigravitySummariesReader.workspaces(#"["file:///a","file:///b"]"#).count == 2)
        #expect(AntigravitySummariesReader.workspaces("").isEmpty)
        #expect(AntigravitySummariesReader.workspaces("/Users/example/plain") == ["/Users/example/plain"])
        #expect(
            AntigravitySummariesReader.path(fromURI: "file:///Users/example/a%20b")
                == "/Users/example/a b")
        #expect(AntigravitySummariesReader.timestamp("0001-01-01 00:00:00+00:00") == nil)
        #expect(AntigravitySummariesReader.timestamp("") == nil)
        #expect(AntigravitySummariesReader.timestamp("2026-07-16 08:18:19.171238+00:00") != nil)
        #expect(AntigravitySummariesReader.timestamp("2026-07-16T08:18:19Z") != nil)
    }
}

// MARK: - The tailer

@Suite("AntigravityConversationTailer")
struct AntigravityConversationTailerTests {
    @Test("a first poll emits every row's opening, and closes the ones already done")
    func firstPoll() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let events = try await tailer(over: url).poll()

        #expect(antigravityLabels(events) == [
            "userPrompt", "textBody.user", "turnStarted",   // idx 0
            "thinking",                                     // idx 1, still generating
            "toolCallStarted",                              // idx 2, still running
            "toolCallStarted", "toolCallFinished",          // idx 3, already done
            "permissionRequested",                          // idx 4, waiting on a person
            "toolCallStarted", "toolCallFinished"           // idx 5
        ])

        let starts = events.compactMap { event -> (String, String, ToolKind, String?)? in
            guard case let .toolCallStarted(id, name, kind, target) = event.kind else { return nil }
            return (id, name, kind, target)
        }
        #expect(starts.map(\.0) == ["tooluse_1", "tooluse_2", "tooluse_3"])
        #expect(starts.map(\.2) == [.shell, .fileWrite, .subagent])
        #expect(starts[0].3 == "swift test --filter TailerTests")
        #expect(starts[1].3 == "/Users/example/code/demo/Tests/TailerTests.swift")
        // The turn is still open: three rows have not settled.
        #expect(antigravityLabels(events).contains { $0.hasPrefix("turnEnded") } == false)
        // The tailer owns the ordering and the back-reference.
        #expect(events.map(\.sequence) == Array(1...Int64(events.count)))
        #expect(events.allSatisfy { $0.raw?.path == url.path })
        #expect(events.first?.raw?.rowID == 0)
        #expect(events.first?.timestamp.timeIntervalSince1970 == Double(base))
    }

    @Test("a row that walked from running to done emits only its close")
    func statusMutation() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        _ = try await subject.poll()

        var finished = canonicalSteps()[2]
        finished.status = .done
        finished.endedAt = base + 20
        finished.transitions.append(.init(status: .done, at: base + 20))
        try AntigravityDatabaseFixture.update(at: url, step: finished)

        let events = try await subject.poll()
        #expect(antigravityLabels(events) == ["toolCallFinished"])
        guard case let .toolCallFinished(id, isError) = events[0].kind else {
            Issue.record("expected a close")
            return
        }
        #expect(id == "tooluse_1")
        #expect(isError == false)
        #expect(events[0].timestamp.timeIntervalSince1970 == Double(base + 20))
        // Sequence numbers keep running across polls.
        #expect(events[0].sequence == 11)
    }

    @Test("a poll that finds nothing changed produces nothing")
    func idempotent() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        _ = try await subject.poll()
        #expect(try await subject.poll().isEmpty)
        #expect(try await subject.poll().isEmpty)
    }

    @Test("a row waiting on a person opens a permission, and leaving it resolves one")
    func permissionCycle() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        let opening = try await subject.poll()

        guard case let .permissionRequested(requestID, tool) = try #require(
            opening.first { if case .permissionRequested = $0.kind { true } else { false } }).kind
        else {
            Issue.record("expected a permission request")
            return
        }
        #expect(requestID == "step-4")
        #expect(tool == "ask_question")

        var answered = canonicalSteps()[4]
        answered.status = .done
        answered.endedAt = base + 30
        try AntigravityDatabaseFixture.update(at: url, step: answered)

        let events = try await subject.poll()
        #expect(antigravityLabels(events) == ["permissionResolved"])
        guard case let .permissionResolved(id, allowed) = events[0].kind else {
            Issue.record("expected a resolution")
            return
        }
        #expect(id == requestID)
        #expect(allowed)
    }

    @Test("a cancelled question resolves as denied")
    func deniedPermission() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        _ = try await subject.poll()

        var refused = canonicalSteps()[4]
        refused.status = .canceled
        try AntigravityDatabaseFixture.update(at: url, step: refused)

        let events = try await subject.poll()
        guard case let .permissionResolved(_, allowed) = try #require(events.first).kind else {
            Issue.record("expected a resolution")
            return
        }
        #expect(allowed == false)
    }

    @Test("the turn closes once every row has settled, and only then")
    func turnEnds() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        _ = try await subject.poll()

        for index in [2, 4] {
            var row = canonicalSteps()[index]
            row.status = .done
            row.endedAt = base + 20
            try AntigravityDatabaseFixture.update(at: url, step: row)
        }
        let mid = try await subject.poll()
        #expect(mid.contains { if case .turnEnded = $0.kind { true } else { false } } == false)

        var reply = canonicalSteps()[1]
        reply.status = .done
        reply.text = "The regression test is in place and the suite is green."
        reply.endedAt = base + 40
        reply.promptTokens = 4_096
        reply.requestID = "req-0002"
        try AntigravityDatabaseFixture.update(at: url, step: reply)

        let events = try await subject.poll()
        #expect(antigravityLabels(events) == [
            "assistantText", "textBody.assistant", "usage", "turnEnded.complete"
        ])
        guard case let .usage(model, input, output, cached) = events[2].kind else {
            Issue.record("expected usage")
            return
        }
        #expect(model == nil)
        #expect(input == 4_096)
        // The payload records no completion count this decoder trusts.
        #expect(output == 0)
        #expect(cached == 0)
    }

    @Test("a planner response with no prose says so rather than emitting an empty reply")
    func replyWithoutText() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: [
            AntigravityStepFixture(idx: 0, type: .plannerResponse, status: .done, startedAt: base)
        ])
        let events = try await tailer(over: url).poll()
        // No `USER_INPUT` row, so no turn ever opened and none is closed —
        // `turnEnded` without a matching start would be noise.
        #expect(antigravityLabels(events) == ["thinking", "note"])
    }

    @Test("a failed row closes as an error and ends the turn as one")
    func errors() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: [
            AntigravityStepFixture(
                idx: 0, type: .runCommand, status: .error,
                toolCall: .init(callID: "tooluse_1", name: "run_command"),
                startedAt: base, endedAt: base + 1),
            AntigravityStepFixture(
                idx: 1, type: .errorMessage, status: .done,
                text: "The command exited with status 1.", startedAt: base + 1)
        ])
        let events = try await tailer(over: url).poll()
        #expect(antigravityLabels(events) == ["toolCallStarted", "toolCallFinished", "note"])
        guard case let .toolCallFinished(_, isError) = events[1].kind else {
            Issue.record("expected a close")
            return
        }
        #expect(isError)
        guard case let .note(text) = events[2].kind else {
            Issue.record("expected a note")
            return
        }
        #expect(text == "error: The command exited with status 1.")
    }

    @Test("a cold start reads a bounded window from the end")
    func seeding() async throws {
        let home = AntigravityHome()
        var steps: [AntigravityStepFixture] = []
        for index in 0..<40 {
            steps.append(AntigravityStepFixture(
                idx: index, type: .viewFile, status: .done,
                toolCall: .init(callID: "tooluse_\(index)", name: "view_file"),
                startedAt: base + UInt64(index), endedAt: base + UInt64(index)))
        }
        let url = try home.write(id: conversationA, steps: steps)

        let subject = tailer(over: url)
        let seeded = try await subject.seedFromTail(maxBytes: 8 * 1024)
        // Eight kilobytes of budget buys eight rows, two events each.
        #expect(seeded.count == 16)
        let ids = seeded.compactMap { event -> String? in
            guard case let .toolCallStarted(id, _, _, _) = event.kind else { return nil }
            return id
        }
        #expect(ids == (32..<40).map { "tooluse_\($0)" })
        #expect(subject.cursor == .rowID(39))
        // Everything before the window stays unread.
        #expect(try await subject.poll().isEmpty)
    }

    @Test("an empty conversation seeds nothing")
    func seedingEmpty() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: [])
        let subject = tailer(over: url)
        #expect(try await subject.seedFromTail(maxBytes: 64 * 1024).isEmpty)
        #expect(subject.cursor == .rowID(-1))
    }

    @Test("a source that is not there yields nothing and keeps its cursor")
    func missingSource() async throws {
        let home = AntigravityHome()
        let subject = tailer(over: home.conversation(id: conversationA))
        #expect(try await subject.poll().isEmpty)
        #expect(subject.cursor == .rowID(-1))
    }
}

// MARK: - Cursors and resuming

@Suite("AntiGravity cursors")
struct AntigravityCursorTests {
    @Test("the cursor is the last row consumed, and survives a round trip")
    func codableRoundTrip() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url)
        _ = try await subject.poll()
        #expect(subject.cursor == .rowID(5))

        let data = try JSONEncoder().encode(subject.cursor)
        #expect(try JSONDecoder().decode(SourceCursor.self, from: data) == subject.cursor)
    }

    @Test("resuming adopts what was already read instead of replaying it")
    func resumeIsSilent() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let first = tailer(over: url)
        _ = try await first.poll()

        let resumed = tailer(over: url, cursor: first.cursor)
        #expect(try await resumed.poll().isEmpty)
        #expect(resumed.cursor == .rowID(5))

        var next = canonicalSteps()[0]
        next.idx = 6
        next.text = "And now check the resume path."
        next.startedAt = base + 100
        try AntigravityDatabaseFixture.update(at: url, step: next)

        let events = try await resumed.poll()
        #expect(antigravityLabels(events) == ["userPrompt", "textBody.user", "turnStarted"])
    }

    @Test("a row still open at the resume point still closes")
    func resumeKeepsOpenRows() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let resumed = tailer(over: url, cursor: .rowID(5))
        #expect(try await resumed.poll().isEmpty)
        #expect(resumed.openRowCount == 3)

        var finished = canonicalSteps()[2]
        finished.status = .done
        finished.endedAt = base + 20
        try AntigravityDatabaseFixture.update(at: url, step: finished)

        let events = try await resumed.poll()
        #expect(antigravityLabels(events) == ["toolCallFinished"])
        guard case let .toolCallFinished(id, _) = events[0].kind else {
            Issue.record("expected a close")
            return
        }
        // The close pairs with the id the previous run would have opened.
        #expect(id == "tooluse_1")
    }

    @Test("a cursor of another store's shape is discarded, not rejected")
    func foreignCursor() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url, cursor: .byteOffset(inode: 42, offset: 4_096))
        #expect(subject.cursor == .rowID(-1))
        #expect(try await subject.poll().count == 10)
    }

    @Test("a composite cursor is looked up by path")
    func compositeCursor() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let subject = tailer(over: url, cursor: .composite([url.path: .rowID(3)]))
        #expect(subject.cursor == .rowID(3))
        // Rows 0 through 3 are adopted; 4 and 5 are new.
        let events = try await subject.poll()
        #expect(antigravityLabels(events) == [
            "permissionRequested", "toolCallStarted", "toolCallFinished"
        ])
    }
}

// MARK: - The reducer

@Suite("AntiGravity events through the reducer")
struct AntigravityReducerTests {
    @Test("a finished conversation folds into an idle row with its calls counted")
    func snapshot() async throws {
        let home = AntigravityHome()
        var steps = canonicalSteps()
        for index in [1, 2, 4] {
            steps[index].status = .done
            steps[index].endedAt = base + 40
        }
        steps[1].text = "Done — the suite is green."
        steps[1].promptTokens = 2_048
        steps[1].requestID = "req-0003"
        let url = try home.write(id: conversationA, steps: steps)

        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: sessionA, sourcePath: url.path))
        for event in try await tailer(over: url).poll() {
            snapshot = reducer.reduce(snapshot, event: event)
        }

        #expect(snapshot.state == .idle)
        #expect(snapshot.turnCount == 1)
        #expect(snapshot.toolCallCount == 3)
        #expect(snapshot.tokensIn == 2_048)
        #expect(snapshot.pending.openToolCalls.isEmpty)
        #expect(snapshot.pending.openPermission == nil)
    }

    @Test("a conversation waiting on a person reduces to blocked, not busy")
    func blocked() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: sessionA, sourcePath: url.path))
        for event in try await tailer(over: url).poll() {
            snapshot = reducer.reduce(snapshot, event: event)
        }
        if case .waitingPermission = snapshot.state {} else {
            Issue.record("expected the session to be blocked, got \(snapshot.state)")
        }
        #expect(snapshot.pending.openPermission != nil)
    }
}

// MARK: - The adapter

@Suite("AntigravityLiveAdapter discovery")
struct AntigravityLiveAdapterDiscoveryTests {
    @Test("both roots' conversations and presence directories are watched")
    func watchRoots() {
        let roots = AntigravityLiveAdapter().watchRoots(home: "/Users/example").map(\.path)
        #expect(roots == [
            "/Users/example/.gemini/antigravity-cli/conversations",
            "/Users/example/.gemini/antigravity-cli/presence",
            "/Users/example/.gemini/antigravity/conversations",
            "/Users/example/.gemini/antigravity/presence",
            "/Users/example/.gemini/antigravity-cli/conversation_summaries.db"
        ])
        #expect(AntigravityLiveAdapter().harness == .antigravity)
    }

    @Test("a CLI conversation is seeded from the index and an IDE one from its file")
    func bothRoots() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        try home.write(id: conversationB, steps: canonicalSteps())
        try home.write(id: conversationC, root: AntigravityLiveAdapter.ideRoot,
                       steps: canonicalSteps())
        try home.writeSummaries([
            .init(id: conversationA, preview: "### Nightly triage", stepCount: 6,
                  workspaces: #"["file:///Users/example/code/demo"]"#),
            .init(id: conversationB, title: "Child run", parent: conversationA, nestingDepth: 1)
        ])

        let adapter = AntigravityLiveAdapter()
        let sources = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        let byID = Dictionary(
            sources.map { ($0.key.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(sources.count == 3)

        let parent = try #require(byID[conversationA]?.seedIdentity)
        #expect(parent.variant == "cli")
        #expect(parent.title == "Nightly triage")
        #expect(parent.cwd == "/Users/example/code/demo")
        #expect(parent.parent == nil)
        #expect(
            canonical(byID[conversationA]?.primaryPath)
                == canonical(home.conversation(id: conversationA).path))

        let child = try #require(byID[conversationB]?.seedIdentity)
        #expect(child.title == "Child run")
        #expect(child.parent == SessionKey(harness: .antigravity, sessionID: conversationA))
        #expect(child.parentLink == .subagent(toolUseID: nil))

        // The IDE writes no index this adapter reads, so its conversation is
        // found by its file and carries nothing it could not know.
        let ide = try #require(byID[conversationC]?.seedIdentity)
        #expect(ide.variant == "ide")
        #expect(ide.title == nil)
        #expect(ide.cwd == nil)

        #expect(adapter.conversationRegistry.children(of: conversationA) == [conversationB])
        #expect(adapter.conversationRegistry.parent(of: conversationB) == conversationA)
    }

    @Test("a conversation nothing has touched since the cutoff is skipped")
    func cutoff() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        try home.write(id: conversationB, steps: canonicalSteps())
        home.backdate(id: conversationB, to: Date().addingTimeInterval(-30 * 86_400))

        let sources = try await AntigravityLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        #expect(sources.map(\.key.sessionID) == [conversationA])
    }

    @Test("busy, or attached, beats the cutoff")
    func busyBeatsTheCutoff() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        try home.write(id: conversationB, steps: canonicalSteps())
        try home.write(id: conversationC, steps: canonicalSteps())
        for id in [conversationA, conversationB, conversationC] {
            home.backdate(id: id, to: Date().addingTimeInterval(-30 * 86_400))
        }
        try home.writeSummaries([
            .init(id: conversationA, title: "Old and busy",
                  lastModified: "2020-01-01 00:00:00.000000+00:00", notFullyIdle: true),
            .init(id: conversationB, title: "Old and quiet",
                  lastModified: "2020-01-01 00:00:00.000000+00:00")
        ])
        home.presence(id: conversationC)

        let sources = try await AntigravityLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        #expect(sources.map(\.key.sessionID) == [conversationA, conversationC])
    }

    @Test("an index row with no database on disk is not a session")
    func indexDrift() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        // The observed shape: the index names conversations that are gone.
        try home.writeSummaries([
            .init(id: conversationA, title: "Here"),
            .init(id: "99999999-9999-9999-9999-999999999999", title: "Gone")
        ])
        let sources = try await AntigravityLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        #expect(sources.map(\.key.sessionID) == [conversationA])
    }

    @Test("an empty home is empty, not an error")
    func emptyHome() async throws {
        let home = AntigravityHome()
        let sources = try await AntigravityLiveAdapter().discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        #expect(sources.isEmpty)
    }

    @Test("a child the index named is announced on its parent's stream")
    func subagentLinking() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        try home.write(id: conversationB, steps: canonicalSteps())
        try home.writeSummaries([
            .init(id: conversationA, title: "Parent"),
            .init(id: conversationB, title: "Child", parent: conversationA, nestingDepth: 1)
        ])

        let adapter = AntigravityLiveAdapter()
        let sources = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        let parent = try #require(sources.first { $0.key.sessionID == conversationA })
        let events = try await adapter.makeTailer(parent, cursor: nil).poll()

        let children = events.compactMap { event -> SessionKey? in
            guard case let .subagentStarted(child, _, _) = event.kind else { return nil }
            return child
        }
        #expect(children == [SessionKey(harness: .antigravity, sessionID: conversationB)])
        #expect(canonical(url.path) == canonical(parent.primaryPath))
    }

    @Test("a killed conversation ends, once")
    func killed() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        try home.writeSummaries([.init(id: conversationA, title: "Stopped", killed: true)])

        let adapter = AntigravityLiveAdapter()
        let sources = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        let subject = try adapter.makeTailer(try #require(sources.first), cursor: nil)
        let first = try await subject.poll()
        #expect(antigravityLabels(first).contains("sessionEnded.killed"))
        #expect(antigravityLabels(try await subject.poll()).contains("sessionEnded.killed") == false)
    }
}

@Suite("AntigravityLiveAdapter liveness")
struct AntigravityLivenessTests {
    private func identity(_ home: AntigravityHome, id: String = conversationA, variant: String = "cli")
        -> SessionIdentity {
        var identity = SessionIdentity(
            key: SessionKey(harness: .antigravity, sessionID: id),
            sourcePath: home.conversation(id: id).path)
        identity.variant = variant
        return identity
    }

    @Test("a presence file touched a moment ago is an attached conversation")
    func freshPresence() throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        home.presence(id: conversationA)

        let hint = AntigravityLiveAdapter().probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.path)
        #expect(hint.verdict == .alive)
        #expect(hint.evidence.contains("presence file touched"))
    }

    @Test("a presence file from last month is evidence of nothing")
    func stalePresence() throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        home.presence(id: conversationA, modified: Date().addingTimeInterval(-30 * 86_400))
        home.backdate(id: conversationA, to: Date().addingTimeInterval(-3_600))

        let hint = AntigravityLiveAdapter().probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.path)
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("untouched"))
    }

    @Test("an agy process whose environment names the conversation is the best answer")
    func environmentMatch() throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        home.backdate(id: conversationA, to: Date().addingTimeInterval(-86_400))

        let record = ProcessRecord(
            pid: 4_711, ppid: 1, startTime: Date(timeIntervalSince1970: Double(base)),
            executablePath: "/Users/example/.local/bin/agy", argv: ["agy"])
        let table = FakeProcessTable(
            records: [record],
            environments: [4_711: [
                AntigravityLiveAdapter.conversationEnvironmentKey: conversationA.uppercased(),
                AntigravityLiveAdapter.trajectoryEnvironmentKey: AntigravityDatabaseFixture.trajectoryID
            ]])

        let hint = AntigravityLiveAdapter().probeLiveness(
            identity(home), table: table, home: home.path)
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4_711)
        #expect(hint.evidence.contains("ANTIGRAVITY_CONVERSATION_ID"))

        // The same process, attached to a different conversation, says nothing
        // about this one.
        let other = AntigravityLiveAdapter().probeLiveness(
            identity(home, id: conversationB), table: table, home: home.path)
        #expect(other.verdict != .alive)
    }

    @Test("the index's own flags decide when the file system cannot")
    func indexFlags() async throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        try home.write(id: conversationB, steps: canonicalSteps())
        for id in [conversationA, conversationB] {
            home.backdate(id: id, to: Date().addingTimeInterval(-86_400))
        }
        try home.writeSummaries([
            .init(id: conversationA, title: "Busy", notFullyIdle: true),
            .init(id: conversationB, title: "Stopped", killed: true)
        ])

        let adapter = AntigravityLiveAdapter()
        _ = try await adapter.discover(home: home.path, activeSince: Date(timeIntervalSince1970: 0))
        let table = FakeProcessTable(records: [])

        let busy = adapter.probeLiveness(identity(home), table: table, home: home.path)
        #expect(busy.verdict == .alive)
        #expect(busy.evidence.contains("not_fully_idle"))

        let stopped = adapter.probeLiveness(
            identity(home, id: conversationB), table: table, home: home.path)
        #expect(stopped.verdict == .dead)
        #expect(stopped.evidence.contains("killed"))
    }

    @Test("with nothing but a timestamp, the honest answers are alive, unknown, and dead")
    func timestampsOnly() throws {
        let home = AntigravityHome()
        try home.write(id: conversationA, steps: canonicalSteps())
        let adapter = AntigravityLiveAdapter()
        let table = FakeProcessTable(records: [])

        let fresh = adapter.probeLiveness(identity(home), table: table, home: home.path)
        #expect(fresh.verdict == .alive)

        home.backdate(id: conversationA, to: Date().addingTimeInterval(-5 * 60))
        let quiet = adapter.probeLiveness(identity(home), table: table, home: home.path)
        #expect(quiet.verdict == .unknown)

        home.backdate(id: conversationA, to: Date().addingTimeInterval(-3_600))
        let old = adapter.probeLiveness(identity(home), table: table, home: home.path)
        #expect(old.verdict == .dead)
    }

    @Test("a conversation whose store is gone is unknown, never dead")
    func missingStore() {
        let home = AntigravityHome()
        let hint = AntigravityLiveAdapter().probeLiveness(
            identity(home), table: FakeProcessTable(records: []), home: home.path)
        #expect(hint.verdict == .unknown)
    }

    @Test("an IDE conversation's presence file is looked for under the IDE root")
    func presenceRootFollowsTheVariant() throws {
        let home = AntigravityHome()
        try home.write(id: conversationC, root: AntigravityLiveAdapter.ideRoot,
                       steps: canonicalSteps())
        var identity = SessionIdentity(
            key: SessionKey(harness: .antigravity, sessionID: conversationC),
            sourcePath: home.conversation(id: conversationC, root: AntigravityLiveAdapter.ideRoot).path)
        identity.variant = "ide"
        #expect(
            AntigravityLiveAdapter().presencePath(for: identity, home: home.path)
                == AntigravityLiveAdapter.presencePath(
                    home: home.path, root: AntigravityLiveAdapter.ideRoot,
                    conversationID: conversationC))
    }
}

// MARK: - Fixture hygiene

@Suite("AntiGravity fixture hygiene")
struct AntigravityFixtureHygieneTests {
    @Test("nothing the adapter emits names a real home directory")
    func syntheticOnly() async throws {
        let home = AntigravityHome()
        let url = try home.write(id: conversationA, steps: canonicalSteps())
        try home.writeSummaries([
            .init(id: conversationA, preview: "### Nightly triage",
                  workspaces: #"["file:///Users/example/code/demo"]"#)
        ])
        let adapter = AntigravityLiveAdapter()
        let sources = try await adapter.discover(
            home: home.path, activeSince: Date().addingTimeInterval(-3_600))
        var texts = sources.flatMap { [$0.seedIdentity.title, $0.seedIdentity.cwd].compactMap { $0 } }
        texts += try await adapter.makeTailer(try #require(sources.first), cursor: nil)
            .poll()
            .flatMap { strings(in: $0.kind) }
        #expect(texts.isEmpty == false)

        let realHome = NSHomeDirectory()
        for text in texts {
            #expect(text.contains(realHome) == false, "a real home directory leaked into an event")
            var index = text.startIndex
            while let found = text.range(of: "/Users/", range: index..<text.endIndex) {
                #expect(
                    text[found.upperBound...].hasPrefix("example"),
                    "an event names a home that is not /Users/example")
                index = found.upperBound
            }
        }
        // Every path an event points at is inside the test's own tree.
        #expect(url.path.hasPrefix(home.path))
    }

    @Test("the shipped fixture directory holds no captured conversation")
    func noCapturedConversations() throws {
        guard let resources = Bundle.module.resourceURL else { return }
        let directory = resources.appendingPathComponent("Fixtures/antigravity")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(names.contains { $0.hasSuffix(".db") } == false)
        #expect(names.contains { $0.hasSuffix(".pb") } == false)
    }
}
