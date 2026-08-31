import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

/// The brief, per harness, over each harness's own record shapes.
///
/// ``SessionBriefTests`` proves the filter in isolation. This suite proves the
/// thing that actually matters: that the envelope *each harness really writes*
/// around a slash command or an injected blob is one the filter recognises, so
/// the assignment on a card is the first thing a person typed rather than the
/// first thing the log recorded. Every harness gets a turn, because every
/// harness spells it differently and only one of them flags it.
///
/// Each test folds real mapper output through the real reducer. Nothing here
/// hand-builds a `userPrompt`.
enum BriefFold {
    /// Folds events into a snapshot the way a host does, in source order.
    static func brief(_ events: [AgentEvent], key: SessionKey) -> SessionBrief {
        let reducer = SessionStateReducer()
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: key, sourcePath: "/Users/example/fixture")
        )
        for event in events {
            snapshot = reducer.reduce(snapshot, event: event)
        }
        return snapshot.brief
    }

    /// A fixed observation clock, so nothing here depends on when the suite runs.
    static let now = Date(timeIntervalSinceReferenceDate: 810_000_000)

    static func lines(_ url: URL) -> [Data] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    static func fixture(_ relativePath: String) throws -> URL {
        let url = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/\(relativePath)")
        try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(relativePath)")
        return url
    }
}

// MARK: - Claude Code and Claude Cowork

@Suite("SessionBrief · Claude Code")
struct ClaudeSessionBriefTests {
    private static let key = SessionKey(harness: .claudeCode, sessionID: ClaudeFixture.sessionID)

    private static func events(_ lines: [Data], key: SessionKey = key) -> [AgentEvent] {
        lines.flatMap {
            ClaudeRecordMapper.events(from: $0, session: key, isSubagent: false, now: claudeNow)
        }
    }

    /// A `type: "user"` record, the way Claude Code writes one.
    private static func userRecord(_ text: String, at stamp: String) -> Data {
        let escaped = String(
            data: try! JSONSerialization.data(withJSONObject: [text], options: []),
            encoding: .utf8
        )!.dropFirst().dropLast()
        return Data("""
        {"type":"user","uuid":"aaaaaaaa-bbbb-cccc-dddd-00000000ffff",\
        "timestamp":"\(stamp)","sessionId":"\(ClaudeFixture.sessionID)",\
        "message":{"role":"user","content":\(escaped)}}
        """.utf8)
    }

    @Test("the transcript fixture's assignment is the first thing the person typed")
    func fixtureAssignment() {
        let brief = BriefFold.brief(Self.events(ClaudeFixture.sessionLines), key: Self.key)
        let assignment = brief.firstPrompt ?? ""
        #expect(assignment.hasPrefix("Add a Claude Code source adapter to AgentSessionLive:"))
        #expect(assignment.count <= SessionBrief.previewLimit)
        // The skill preamble on line 11 is `isMeta`, so the mapper never
        // offers it and the brief never sees it.
        #expect(brief.latestPrompt == brief.firstPrompt)
        #expect(brief.latestAssistant
            == "The mapper, the adapter, and the sessions-directory reader are in place; tests are green.")
        #expect(brief.lastTurnEndedAt != nil)
    }

    @Test("a slash-command echo ahead of the real instruction is skipped")
    func slashCommandEchoSkipped() {
        let echo = "<command-name>/compact</command-name>"
            + "\n<command-message>compact</command-message>\n<command-args></command-args>"
        let lines = [
            Self.userRecord(echo, at: "2026-01-05T08:59:00.000Z"),
            Self.userRecord("port the reducer to the new event model", at: "2026-01-05T08:59:30.000Z"),
        ]
        let brief = BriefFold.brief(Self.events(lines), key: Self.key)
        #expect(brief.firstPrompt == "port the reducer to the new event model")
    }

    @Test("a hook's stdout ahead of the real instruction is skipped")
    func localCommandOutputSkipped() {
        let lines = [
            Self.userRecord("<local-command-stdout>3 files changed</local-command-stdout>",
                            at: "2026-01-05T08:59:00.000Z"),
            Self.userRecord("port the reducer to the new event model", at: "2026-01-05T08:59:30.000Z"),
        ]
        let brief = BriefFold.brief(Self.events(lines), key: Self.key)
        #expect(brief.firstPrompt == "port the reducer to the new event model")
    }
}

@Suite("SessionBrief · Claude Cowork")
struct ClaudeCoworkSessionBriefTests {
    /// Cowork's transcripts are Claude Code's, written inside Claude.app's
    /// container — `ClaudeCoworkLiveAdapter` reuses `ClaudeRecordMapper`
    /// unchanged — so the only thing worth asserting separately is that the
    /// key's harness does not change the answer.
    @Test("a Cowork transcript reads the same as a Claude Code one")
    func coworkReadsTheSame() {
        let key = SessionKey(harness: .claudeCowork, sessionID: ClaudeFixture.sessionID)
        let events = ClaudeFixture.sessionLines.flatMap {
            ClaudeRecordMapper.events(from: $0, session: key, isSubagent: false, now: claudeNow)
        }
        let brief = BriefFold.brief(events, key: key)
        #expect(brief.firstPrompt?.hasPrefix("Add a Claude Code source adapter") == true)
    }
}

// MARK: - Codex and ChatGPT Work

@Suite("SessionBrief · Codex")
struct CodexSessionBriefTests {
    private static let key = SessionKey(
        harness: .codex, sessionID: "11111111-2222-3333-4444-555555555555")

    private static func events(_ lines: [Data], key: SessionKey = key) -> [AgentEvent] {
        lines.flatMap { CodexRecordMapper.events(from: $0, session: key, now: BriefFold.now) }
    }

    /// An `event_msg` / `user_message` record, the way Codex writes one.
    private static func userMessage(_ text: String, at stamp: String) -> Data {
        let escaped = String(
            data: try! JSONSerialization.data(withJSONObject: [text], options: []),
            encoding: .utf8
        )!.dropFirst().dropLast()
        return Data("""
        {"timestamp":"\(stamp)","type":"event_msg",\
        "payload":{"type":"user_message","message":\(escaped),"images":[]}}
        """.utf8)
    }

    @Test("the rollout fixture's assignment, follow-up, and last reply")
    func fixtureBrief() throws {
        let brief = BriefFold.brief(
            Self.events(BriefFold.lines(try BriefFold.fixture("codex/rollout.jsonl"))),
            key: Self.key
        )
        #expect(brief.firstPrompt == "Add a regression test for the JSONL tailer.")
        #expect(brief.followUpPrompt == "Now make the cursor survive a rotation.")
        #expect(brief.latestAssistant == "The build needs the Testing module wired in first.")
        #expect(brief.lastTurnEndedAt != nil)
    }

    @Test("the environment blob a rollout opens with is not the assignment")
    func environmentContextSkipped() {
        let blob = "<environment_context>\n  <cwd>/Users/example/code/demo</cwd>\n"
            + "  <approval_policy>on-request</approval_policy>\n</environment_context>"
        let lines = [
            Self.userMessage(blob, at: "2026-01-01T00:00:03.000Z"),
            Self.userMessage("<user_instructions>Always run the suite.</user_instructions>",
                             at: "2026-01-01T00:00:03.500Z"),
            Self.userMessage("split the ingest coordinator in two", at: "2026-01-01T00:00:04.000Z"),
        ]
        let brief = BriefFold.brief(Self.events(lines), key: Self.key)
        #expect(brief.firstPrompt == "split the ingest coordinator in two")
    }

    @Test("a ChatGPT Work rollout reads the same as a Codex one")
    func chatgptWorkReadsTheSame() throws {
        let key = SessionKey(harness: .chatgptWork, sessionID: Self.key.sessionID)
        let brief = BriefFold.brief(
            Self.events(BriefFold.lines(try BriefFold.fixture("codex/rollout.jsonl")), key: key),
            key: key
        )
        #expect(brief.firstPrompt == "Add a regression test for the JSONL tailer.")
    }
}

// MARK: - Grok Build

@Suite("SessionBrief · Grok Build")
struct GrokSessionBriefTests {
    private static let key = SessionKey(
        harness: .grokBuild, sessionID: "77777777-8888-9999-aaaa-bbbbbbbbbbbb")

    private static func events(_ lines: [Data]) -> [AgentEvent] {
        lines.flatMap {
            GrokRecordMapper.eventsFromUpdates($0, session: key, now: BriefFold.now)
        }
    }

    /// A `user_message_chunk` update, the way Grok Build writes one.
    private static func userChunk(_ text: String, at seconds: Int) -> Data {
        let escaped = String(
            data: try! JSONSerialization.data(withJSONObject: [text], options: []),
            encoding: .utf8
        )!.dropFirst().dropLast()
        return Data("""
        {"timestamp":\(seconds),"method":"_x.ai/session/update",\
        "params":{"sessionId":"\(key.sessionID)",\
        "update":{"sessionUpdate":"user_message_chunk",\
        "content":{"type":"text","text":\(escaped)}}}}
        """.utf8)
    }

    @Test("the updates fixture's assignment and last reply")
    func fixtureBrief() throws {
        let brief = BriefFold.brief(
            Self.events(BriefFold.lines(try BriefFold.fixture("grok/session/updates.jsonl"))),
            key: Self.key
        )
        #expect(brief.firstPrompt == "Add a regression test for the tailer.")
        #expect(brief.latestAssistant == "Done: the regression test is in place.")
        #expect(brief.lastTurnEndedAt != nil)
    }

    @Test("a slash-command chunk ahead of the real instruction is skipped")
    func slashCommandSkipped() {
        let lines = [
            Self.userChunk("<command-name>/clear</command-name>", at: 1_767_225_600),
            Self.userChunk("teach the tailer about rotation", at: 1_767_225_601),
        ]
        let brief = BriefFold.brief(Self.events(lines), key: Self.key)
        #expect(brief.firstPrompt == "teach the tailer about rotation")
    }
}

// MARK: - Cursor

@Suite("SessionBrief · Cursor")
struct CursorSessionBriefTests {
    private static let key = SessionKey(harness: .cursor, sessionID: "cursor-agent-0001")

    private static func events(_ lines: [Data]) -> [AgentEvent] {
        lines.flatMap {
            CursorThinTranscriptMapper.events(from: $0, session: key, now: BriefFold.now)
        }
    }

    @Test("the thin transcript's assignment survives its timestamp header")
    func fixtureBrief() throws {
        let brief = BriefFold.brief(
            Self.events(BriefFold.lines(try BriefFold.fixture("cursor/thin-transcript.jsonl"))),
            key: Self.key
        )
        #expect(brief.firstPrompt == "add a test for the reducer")
        #expect(brief.lastTurnEndedAt != nil)
        // Assistant prose is the store's to report, never the thin
        // transcript's, so a brief folded from this file alone has none.
        #expect(brief.latestAssistant == nil)
    }

    @Test("a slash-command line ahead of the real instruction is skipped")
    func slashCommandSkipped() {
        let lines = [
            Data(CursorFixture.transcriptUserLine("<command-name>/clear</command-name>").utf8),
            Data(CursorFixture.transcriptUserLine("rename the store reader").utf8),
        ]
        let brief = BriefFold.brief(Self.events(lines), key: Self.key)
        #expect(brief.firstPrompt == "rename the store reader")
    }

    @Test("the store's prose is what fills the reply line")
    func storeProse() throws {
        let json = CursorFixture.assistantMessage([CursorFixture.textPart("Added a table test.")])
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let message = try #require(
            CursorMessage.decode(object, ref: CursorMessageRef(blobID: "0a0b0c0d")))
        let events = CursorMessageMapper.events(
            from: message, session: Self.key, now: BriefFold.now, emitsUserPrompt: false)
        #expect(BriefFold.brief(events, key: Self.key).latestAssistant == "Added a table test.")
    }
}

// MARK: - Grok Bot

@Suite("SessionBrief · Grok Bot")
struct GrokBotSessionBriefTests {
    private static let key = GrokBotFixture.session(GrokBotFixture.scout)

    private static func events(_ json: [String]) -> [AgentEvent] {
        json.enumerated().flatMap { index, text -> [AgentEvent] in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any],
                let entry = GrokBotEntry(json: object)
            else { return [] }
            return GrokBotEntryMapper.events(
                for: entry,
                session: key,
                sourcePath: "/Users/example/fixture.json",
                index: index,
                now: BriefFold.now
            )
        }
    }

    @Test("the conversation's assignment and the bot's last reply")
    func conversationBrief() {
        let brief = BriefFold.brief(Self.events([
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "watch the release channel"),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "Watching. I will report on any tag."),
        ]), key: Self.key)

        #expect(brief.firstPrompt == "watch the release channel")
        #expect(brief.latestAssistant == "Watching. I will report on any tag.")
    }

    @Test("a slash-command prompt ahead of the real instruction is skipped")
    func slashCommandSkipped() {
        let brief = BriefFold.brief(Self.events([
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "<command-name>/reset</command-name>"),
            GrokBotEntryJSON.prompt(id: "e2", at: 2, text: "watch the release channel"),
        ]), key: Self.key)

        #expect(brief.firstPrompt == "watch the release channel")
    }
}

// MARK: - AntiGravity

@Suite("SessionBrief · AntiGravity")
struct AntigravitySessionBriefTests {
    private static let key = SessionKey(
        harness: .antigravity, sessionID: AntigravityDatabaseFixture.trajectoryID)

    private static func row(_ step: AntigravityStepFixture) -> AntigravityConversationReader.StepRow {
        AntigravityConversationReader.StepRow(
            idx: step.idx,
            rawStepType: step.type.rawValue,
            rawStatus: step.status.rawValue,
            hasSubtrajectory: step.hasSubtrajectory,
            payload: AntigravityStepPayload.decode(step.payload)
        )
    }

    private static func events(_ steps: [AntigravityStepFixture]) -> [AgentEvent] {
        steps.flatMap {
            AntigravityStepMapper.map(
                row: row($0),
                previous: nil,
                session: key,
                sourcePath: "/Users/example/fixture.db",
                now: BriefFold.now
            ).events
        }
    }

    @Test("a conversation's assignment and the planner's last prose")
    func conversationBrief() {
        let brief = BriefFold.brief(Self.events([
            AntigravityStepFixture(idx: 0, type: .userInput, status: .done,
                                   text: "convert the index to a WAL-aware poll"),
            AntigravityStepFixture(idx: 1, type: .plannerResponse, status: .done,
                                   text: "The poll now reads the WAL first."),
        ]), key: Self.key)

        #expect(brief.firstPrompt == "convert the index to a WAL-aware poll")
        #expect(brief.latestAssistant == "The poll now reads the WAL first.")
    }

    @Test("a slash-command step ahead of the real instruction is skipped")
    func slashCommandSkipped() {
        let brief = BriefFold.brief(Self.events([
            AntigravityStepFixture(idx: 0, type: .userInput, status: .done,
                                   text: "<command-name>/clear</command-name>"),
            AntigravityStepFixture(idx: 1, type: .userInput, status: .done,
                                   text: "convert the index to a WAL-aware poll"),
        ]), key: Self.key)

        #expect(brief.firstPrompt == "convert the index to a WAL-aware poll")
    }
}
