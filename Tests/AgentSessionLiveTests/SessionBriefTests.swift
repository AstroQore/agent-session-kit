import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("SessionBrief instructions")
struct SessionBriefInstructionTests {
    @Test("plain prose is kept verbatim")
    func plainProse() {
        #expect(SessionBrief.instruction("Add a regression test for the JSONL tailer.")
            == "Add a regression test for the JSONL tailer.")
    }

    @Test("whitespace is collapsed onto one line")
    func collapsed() {
        #expect(SessionBrief.instruction("  fix\n\nthe   parser\t") == "fix the parser")
    }

    @Test("a preview never exceeds the limit")
    func truncated() throws {
        let long = String(repeating: "a", count: 400)
        let preview = try #require(SessionBrief.instruction(long))
        #expect(preview.count == SessionBrief.previewLimit)
        #expect(preview.hasSuffix("…"))
    }

    @Test("empty and whitespace-only prompts are not instructions", arguments: ["", "   ", "\n\t "])
    func empty(_ text: String) {
        #expect(SessionBrief.instruction(text) == nil)
    }

    // MARK: - The envelopes a person did not type

    @Test("a Claude Code slash-command echo carries no instruction")
    func claudeSlashCommandEcho() {
        let echo = "<command-name>/compact</command-name>"
            + "<command-message>compact</command-message>"
            + "<command-args></command-args>"
        #expect(SessionBrief.instruction(echo) == nil)
    }

    @Test("a slash command with an argument keeps the argument")
    func slashCommandWithArguments() {
        let text = "<command-name>/dual-supervisor</command-name>"
            + "<command-args>rewrite the parser</command-args> rewrite the parser"
        #expect(SessionBrief.instruction(text) == "rewrite the parser")
    }

    @Test("a bare slash command is a command to the harness, not a task")
    func bareSlashCommand() {
        #expect(SessionBrief.instruction("/clear") == nil)
        #expect(SessionBrief.instruction("/model opus") == "/model opus")
    }

    @Test("local command output is stripped, whatever the suffix", arguments: [
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
    ])
    func localCommandBlocks(_ tag: String) {
        #expect(SessionBrief.instruction("<\(tag)>4 files changed</\(tag)>") == nil)
    }

    @Test("a system reminder around a real instruction leaves the instruction")
    func systemReminderAroundProse() {
        let text = "<system-reminder>Your todo list is empty.</system-reminder>"
            + " now make the cursor survive a rotation"
        #expect(SessionBrief.instruction(text) == "now make the cursor survive a rotation")
    }

    @Test("a truncated meta block swallows the rest of the preview")
    func truncatedMetaBlock() {
        #expect(SessionBrief.instruction("<system-reminder>You have been asked to…") == nil)
        #expect(SessionBrief.instruction("do the thing <system-reminder>You have been…")
            == "do the thing")
    }

    @Test("a preview that begins inside a meta block keeps what follows it")
    func previewBeginsMidBlock() {
        #expect(SessionBrief.instruction("…files were read.</system-reminder> ship it") == "ship it")
    }

    @Test("a preview cut inside the tag name is still recognised")
    func truncatedTagName() {
        #expect(SessionBrief.instruction("ship it <system-remind") == "ship it")
        #expect(SessionBrief.instruction("compare a < b for me") == "compare a < b for me")
    }

    @Test("Codex's developer blobs are not instructions", arguments: [
        "environment_context", "user_instructions", "app-context",
    ])
    func codexDeveloperBlobs(_ tag: String) {
        #expect(SessionBrief.instruction("<\(tag)><cwd>/Users/example/code/demo</cwd></\(tag)>") == nil)
    }

    @Test("ordinary angle brackets are left alone")
    func nonMetaMarkup() {
        #expect(SessionBrief.instruction("wrap it in <div> and check <b>bold</b>")
            == "wrap it in <div> and check <b>bold</b>")
    }
}

@Suite("SessionBrief recording")
struct SessionBriefRecordingTests {
    @Test("the first instruction is the assignment and the last one is the follow-up")
    func firstAndLatest() {
        var brief = SessionBrief()
        brief.record(prompt: "add a test", at: epoch)
        brief.record(prompt: "now make it green", at: epoch.addingTimeInterval(60))

        #expect(brief.firstPrompt == "add a test")
        #expect(brief.firstPromptAt == epoch)
        #expect(brief.latestPrompt == "now make it green")
        #expect(brief.lastPromptAt == epoch.addingTimeInterval(60))
        #expect(brief.followUpPrompt == "now make it green")
    }

    @Test("one prompt is the assignment and no follow-up")
    func singlePrompt() {
        var brief = SessionBrief()
        brief.record(prompt: "add a test", at: epoch)
        #expect(brief.latestPrompt == brief.firstPrompt)
        #expect(brief.followUpPrompt == nil)
    }

    @Test("a meta prompt moves nothing at all")
    func metaPromptIsInert() {
        var brief = SessionBrief()
        brief.record(prompt: "add a test", at: epoch)
        brief.record(prompt: "<command-name>/compact</command-name>", at: epoch.addingTimeInterval(60))

        #expect(brief.firstPrompt == "add a test")
        #expect(brief.latestPrompt == "add a test")
        #expect(brief.lastPromptAt == epoch)
    }

    @Test("a line flushed out of order never overwrites a newer one")
    func outOfOrderLines() {
        var brief = SessionBrief()
        brief.record(prompt: "second", at: epoch.addingTimeInterval(60))
        brief.record(reply: "later reply", at: epoch.addingTimeInterval(60))
        brief.recordTurnEnded(at: epoch.addingTimeInterval(60))

        brief.record(prompt: "first", at: epoch)
        brief.record(reply: "earlier reply", at: epoch)
        brief.recordTurnEnded(at: epoch)

        // The earlier prompt is the better answer for the assignment and the
        // worse one for "what was asked last".
        #expect(brief.firstPrompt == "first")
        #expect(brief.firstPromptAt == epoch)
        #expect(brief.latestPrompt == "second")
        #expect(brief.latestAssistant == "later reply")
        #expect(brief.lastTurnEndedAt == epoch.addingTimeInterval(60))
    }

    @Test("an empty reply is ignored")
    func emptyReply() {
        var brief = SessionBrief()
        brief.record(reply: "   ", at: epoch)
        #expect(brief.latestAssistant == nil)
        #expect(brief.lastAssistantAt == nil)
    }

    @Test("an untouched brief is empty and round-trips")
    func emptyBrief() throws {
        let brief = SessionBrief()
        #expect(brief.isEmpty)
        #expect(brief.followUpPrompt == nil)
        let decoded = try JSONDecoder().decode(SessionBrief.self, from: JSONEncoder().encode(brief))
        #expect(decoded == brief)
    }

    @Test("a populated brief round-trips")
    func populatedRoundTrip() throws {
        var brief = SessionBrief()
        brief.record(prompt: "add a test", at: epoch)
        brief.record(reply: "Done — the suite is green.", at: epoch.addingTimeInterval(30))
        brief.recordTurnEnded(at: epoch.addingTimeInterval(31))

        #expect(!brief.isEmpty)
        let decoded = try JSONDecoder().decode(SessionBrief.self, from: JSONEncoder().encode(brief))
        #expect(decoded == brief)
    }
}

@Suite("SessionBrief in the reducer")
struct SessionBriefReducerTests {
    @Test("a turn fills the brief in")
    func aTurnFillsTheBrief() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "add a regression test for the tailer"),
            .thinking,
            .toolCallStarted(id: "t1", name: "Bash", kind: .shell, target: "swift test"),
            .toolCallFinished(id: "t1", isError: false),
            .assistantText(preview: "The tailer test is in place and the suite is green."),
            .turnEnded(reason: .complete),
        ])

        let brief = harness.snapshot.brief
        #expect(brief.firstPrompt == "add a regression test for the tailer")
        #expect(brief.latestPrompt == brief.firstPrompt)
        #expect(brief.latestAssistant == "The tailer test is in place and the suite is green.")
        #expect(brief.lastTurnEndedAt == harness.clock)
        #expect(brief.followUpPrompt == nil)
    }

    @Test("a second turn keeps the assignment and moves the follow-up")
    func secondTurn() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "add a regression test for the tailer"),
            .assistantText(preview: "Done."),
            .turnEnded(reason: .complete),
            .userPrompt(preview: "now make the cursor survive a rotation"),
            .assistantText(preview: "The build needs the Testing module wired in first."),
        ])

        let brief = harness.snapshot.brief
        #expect(brief.firstPrompt == "add a regression test for the tailer")
        #expect(brief.followUpPrompt == "now make the cursor survive a rotation")
        #expect(brief.latestAssistant == "The build needs the Testing module wired in first.")
    }

    @Test("a slash-command turn still counts as a turn but says nothing")
    func slashCommandTurn() {
        var harness = ReducerHarness()
        harness.send(.userPrompt(preview: "<command-name>/compact</command-name>"))

        #expect(harness.snapshot.turnCount == 1)
        #expect(harness.state == .thinking)
        #expect(harness.snapshot.brief.isEmpty)
    }

    @Test("the assignment survives a restart")
    func assignmentSurvivesRestart() {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "ship the ledger"),
            .turnEnded(reason: .complete),
            .sessionEnded(reason: .exited),
            .sessionStarted(identity: makeIdentity()),
        ])

        #expect(harness.state == .idle)
        #expect(harness.snapshot.brief.firstPrompt == "ship the ledger")
    }

    @Test("an ended session still records the words that arrive late")
    func endedSessionStillRecords() {
        var harness = ReducerHarness()
        harness.send(.sessionEnded(reason: .killed))
        harness.send(.assistantText(preview: "one last line"))

        #expect(harness.state == .ended(reason: .killed))
        #expect(harness.snapshot.brief.latestAssistant == "one last line")
    }

    @Test("a brief travels through a snapshot round-trip")
    func snapshotRoundTrip() throws {
        var harness = ReducerHarness()
        harness.send([
            .userPrompt(preview: "ship the ledger"),
            .assistantText(preview: "On it."),
            .turnEnded(reason: .complete),
        ])
        let snapshot = harness.snapshot
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.brief == snapshot.brief)
    }
}
