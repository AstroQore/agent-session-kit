import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("ClaudeRecordMapper")
struct ClaudeRecordMapperTests {
    /// The whole fixture transcript, mapped.
    private func sessionEvents() -> [AgentEvent] {
        ClaudeFixture.sessionLines.flatMap {
            ClaudeRecordMapper.events(
                from: $0, session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
            )
        }
    }

    private func subagentEvents() -> [AgentEvent] {
        ClaudeFixture.subagentLines.flatMap {
            ClaudeRecordMapper.events(
                from: $0, session: ClaudeFixture.childKey, isSubagent: true, now: claudeNow
            )
        }
    }

    // MARK: - The whole file

    @Test("every record type in the fixture maps to the events it should")
    func kindCounts() {
        #expect(ClaudeFixture.sessionLines.count == 30)
        #expect(sessionEvents().kindCounts == [
            // One per fully-stamped record, plus `worktree-state` and
            // `custom-title`. The tailer collapses these; the mapper cannot,
            // because it sees one line at a time.
            "identityUpdated": 25,
            // The one human prompt. The `isMeta` skill preamble is not one.
            "userPrompt": 1,
            "thinking": 1,
            "assistantText": 3,
            "toolCallStarted": 11,
            "toolCallFinished": 11,
            // One per assistant record.
            "usage": 8,
            // The single `stop_reason: "end_turn"`.
            "turnEnded": 1,
            // `system` / `compact_boundary`.
            "compaction": 1,
            // The one `queue-operation`.
            "note": 1,
            // 1 prompt + 3 assistant messages + 11 tool results.
            "textBody": 15
        ])
    }

    @Test("attachment, mode, pr-link, last-prompt, and file-history-snapshot carry no events")
    func ignoredRecordTypes() {
        let ignored = [
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"type":"pr-link","sessionId":"s","prNumber":7}"#,
            #"{"type":"last-prompt","lastPrompt":"hi","sessionId":"s"}"#,
            #"{"type":"file-history-snapshot","messageId":"m","snapshot":{}}"#,
            #"{"type":"relocated","sessionId":"s"}"#,
            #"{"type":"attachment","attachment":{"type":"deferred_tools_delta"}}"#
        ]
        for line in ignored {
            let events = ClaudeRecordMapper.events(
                from: Data(line.utf8), session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
            )
            #expect(events.isEmpty, "\(line) should map to nothing")
        }
    }

    @Test("a line that is not a JSON object yields no events and does not trap")
    func garbageLines() {
        for line in ["", "not json", "[1,2,3]", "null", #"{"type":}"#] {
            let events = ClaudeRecordMapper.events(
                from: Data(line.utf8), session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
            )
            #expect(events.isEmpty)
        }
    }

    // MARK: - Tool calls

    @Test("every tool call is normalised to the right kind and target")
    func toolKinds() {
        let started = sessionEvents().values(StartedCall.init)
        #expect(started.count == 11)

        let byID = Dictionary(uniqueKeysWithValues: started.map { ($0.id, $0) })

        #expect(byID["toolu_bash01"]?.kind == .shell)
        #expect(byID["toolu_bash01"]?.name == "Bash")
        #expect(byID["toolu_bash01"]?.target == "swift build 2>&1 | tail -5")

        #expect(byID["toolu_read01"]?.kind == .fileRead)
        #expect(byID["toolu_read01"]?.target == "/Users/example/code/demo/Sources/Tailing/JSONLTailer.swift")

        #expect(byID["toolu_edit01"]?.kind == .fileWrite)
        #expect(byID["toolu_edit01"]?.target == "/Users/example/code/demo/Sources/Adapters/ClaudeRecordMapper.swift")

        #expect(byID["toolu_write01"]?.kind == .fileWrite)
        #expect(byID["toolu_write01"]?.target == "/Users/example/code/demo/Tests/MapperTests.swift")

        #expect(byID["toolu_grep01"]?.kind == .search)
        #expect(byID["toolu_grep01"]?.target == "textBodyLimit")

        #expect(byID["toolu_web01"]?.kind == .web)
        #expect(byID["toolu_web01"]?.target == "https://example.com/docs/jsonl")

        // The server half of `mcp__<server>__<tool>`, not the whole name.
        #expect(byID["toolu_mcp01"]?.kind == .mcp)
        #expect(byID["toolu_mcp01"]?.target == "demo_server")

        #expect(byID["toolu_todo01"]?.kind == .plan)

        // A tool this package has never heard of is `other`, never a guess.
        #expect(byID["toolu_skill01"]?.kind == .other)

        #expect(byID["toolu_task01"]?.kind == .subagent)
        #expect(byID["toolu_task01"]?.target == "Survey the fixture record types")
    }

    @Test("a Task tool call does not announce a subagent")
    func taskDoesNotStartASubagent() {
        // The parent's line records a tool-use id and nothing that identifies
        // the child; `ClaudeSubagentLinker` owns the join.
        #expect(sessionEvents().kindCounts["subagentStarted"] == nil)
    }

    @Test("each tool result closes its own call, error flag included")
    func toolResults() {
        let finished = sessionEvents().values(FinishedCall.init)
        #expect(finished.count == 11)
        #expect(finished.contains(FinishedCall(.toolCallFinished(id: "toolu_bash01", isError: false))!))
        // The one failed `Edit`.
        #expect(finished.contains(FinishedCall(.toolCallFinished(id: "toolu_edit02", isError: true))!))
        #expect(finished.filter(\.isError).count == 1)

        // Every started call is closed, and nothing is closed twice.
        let started = Set(sessionEvents().values(StartedCall.init).map(\.id))
        #expect(Set(finished.map(\.id)) == started)
    }

    @Test("a tool result's body prefers the toolUseResult sidecar over the block")
    func toolResultBodies() {
        let bodies = sessionEvents().values(Body.init).filter { $0.role == .toolResult }
        #expect(bodies.count == 11)
        // `Bash` writes its real output into the sidecar; the block holds the
        // same text here, but the sidecar is what was read.
        let bash = bodies.first { $0.toolCallID == "toolu_bash01" }
        #expect(bash?.text == "Build complete! (1.22s)")
        // A structured sidecar is not text, so the block's own content stands.
        let read = bodies.first { $0.toolCallID == "toolu_read01" }
        #expect(read?.text == "     1\tpublic final class JSONLTailer: SessionTailer {")
        // Every tool-result body names the call it belongs to.
        #expect(bodies.allSatisfy { $0.toolCallID != nil })
    }

    // MARK: - Text

    @Test("a prompt is previewed at 200 characters and carried in full alongside")
    func promptPreviewAndBody() {
        let events = sessionEvents()
        guard case let .userPrompt(preview)? = events.firstValue({
            if case .userPrompt = $0 { return $0 }
            return nil
        }) else {
            Issue.record("no userPrompt in the fixture")
            return
        }
        #expect(preview.count <= 200)
        #expect(preview.hasPrefix("Add a Claude Code source adapter"))
        #expect(preview.hasSuffix("…"))

        let body = events.values(Body.init).first { $0.role == .user }
        #expect(body != nil)
        #expect(body?.text.count ?? 0 > preview.count)
        #expect(body?.text.hasSuffix("testable without a clock.") == true)
        #expect(body?.toolCallID == nil)
    }

    @Test("an isMeta user record is injected context, not a person")
    func metaRecordsAreNotPrompts() {
        let line = #"""
        {"type":"user","uuid":"u1","sessionId":"s","cwd":"/Users/example/code/demo",\#
        "timestamp":"2026-01-05T09:00:00.000Z","isMeta":true,\#
        "message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]}}
        """#
        let events = ClaudeRecordMapper.events(
            from: Data(line.utf8), session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
        )
        #expect(events.kindCounts == ["identityUpdated": 1])
    }

    @Test("assistant prose is previewed and carried in full")
    func assistantText() {
        let events = sessionEvents()
        let previews = events.values { kind -> String? in
            guard case let .assistantText(preview) = kind else { return nil }
            return preview
        }
        #expect(previews.count == 3)
        #expect(previews.allSatisfy { $0.count <= 200 })
        #expect(events.values(Body.init).filter { $0.role == .assistant }.count == 3)
    }

    @Test("a text body is capped at the limit on a character boundary")
    func textBodyIsBounded() {
        // Four-byte scalars, so a byte-wise cut would land mid-character.
        let huge = String(repeating: "🧪", count: AgentEventKind.textBodyLimit)
        let bounded = ClaudeRecordMapper.bounded(huge)
        #expect(bounded.utf8.count <= AgentEventKind.textBodyLimit)
        #expect(bounded.count == AgentEventKind.textBodyLimit / 4)
        // Nothing under the limit is touched.
        #expect(ClaudeRecordMapper.bounded("short") == "short")
    }

    // MARK: - Usage and turns

    @Test("token counts are summed per assistant record, cache reads and writes folded together")
    func usage() {
        let totals = usageTotals(sessionEvents())
        // Seven records at 4/60/(100+900), one at 6/90/(200+1800).
        #expect(totals.input == 7 * 4 + 6)
        #expect(totals.output == 7 * 60 + 90)
        #expect(totals.cached == 7 * 1000 + 2000)

        let models = Set(sessionEvents().values { kind -> String? in
            guard case let .usage(model, _, _, _) = kind else { return nil }
            return model
        })
        #expect(models == ["claude-fable-5"])
    }

    @Test("only end_turn closes a turn")
    func turnEnds() {
        let reasons = sessionEvents().values { kind -> TurnEndReason? in
            guard case let .turnEnded(reason) = kind else { return nil }
            return reason
        }
        #expect(reasons == [.complete])

        // `stop_reason: "tool_use"` is a model still working.
        let stillWorking = #"""
        {"type":"assistant","uuid":"u1","sessionId":"s","cwd":"/Users/example/code/demo",\#
        "timestamp":"2026-01-05T09:00:00.000Z","message":{"role":"assistant","model":"m",\#
        "stop_reason":"tool_use","content":[{"type":"text","text":"working"}]}}
        """#
        let events = ClaudeRecordMapper.events(
            from: Data(stillWorking.utf8), session: ClaudeFixture.parentKey,
            isSubagent: false, now: claudeNow
        )
        #expect(events.kindCounts["turnEnded"] == nil)
    }

    @Test("a synthetic model never reaches an identity")
    func syntheticModelIsDropped() {
        let line = #"""
        {"type":"assistant","uuid":"u1","sessionId":"s","cwd":"/Users/example/code/demo",\#
        "timestamp":"2026-01-05T09:00:00.000Z","message":{"role":"assistant","model":"<synthetic>",\#
        "stop_reason":"end_turn","content":[{"type":"text","text":"No conversation found."}]}}
        """#
        let events = ClaudeRecordMapper.events(
            from: Data(line.utf8), session: ClaudeFixture.parentKey, isSubagent: false, now: claudeNow
        )
        #expect(events.values(identityPatch).first?.model == nil)
    }

    // MARK: - Identity

    @Test("custom-title becomes a title patch")
    func customTitle() {
        let titles = sessionEvents().values(identityPatch).compactMap(\.title)
        #expect(titles == ["Claude Code live adapter"])
    }

    @Test("worktree-state moves the cwd and the branch")
    func worktreeState() {
        let patches = sessionEvents().values(identityPatch)
        #expect(patches.contains { $0.cwd == ClaudeFixture.worktree })
        #expect(patches.contains { $0.gitBranch == ClaudeFixture.worktreeBranch })
        // The session started on `main` and moved, and both are recorded.
        #expect(patches.contains { $0.cwd == ClaudeFixture.cwd })
        #expect(patches.contains { $0.gitBranch == "main" })
    }

    @Test("a subagent's patches claim the subagent variant and not the parent's entrypoint")
    func subagentIdentity() {
        let patches = subagentEvents().values(identityPatch)
        #expect(patches.allSatisfy { $0.entrypoint == nil })
        #expect(patches.allSatisfy { $0.variant == ClaudeLiveAdapter.subagentVariant })

        // The parent's do the opposite.
        let parent = sessionEvents().values(identityPatch)
        #expect(parent.contains { $0.entrypoint == "claude-desktop" })
        #expect(parent.allSatisfy { $0.variant == nil })
    }

    @Test("a queue-operation becomes one short note")
    func queueOperation() {
        let notes = sessionEvents().values { kind -> String? in
            guard case let .note(text) = kind else { return nil }
            return text
        }
        #expect(notes.count == 1)
        #expect(notes.first?.hasPrefix("queued: enqueue — ") == true)
        #expect(notes.first?.count ?? 0 <= 100)
    }

    // MARK: - Clocks

    @Test("a record's own timestamp is kept; an auxiliary record borrows the observation clock")
    func timestamps() {
        let events = sessionEvents()
        #expect(events.allSatisfy { $0.observedAt == claudeNow })

        // `custom-title` is the last record and carries no timestamp at all.
        #expect(events.last?.timestamp == claudeNow)
        // A conversation record keeps the source's own.
        let firstPrompt = events.first { if case .userPrompt = $0.kind { return true } else { return false } }
        #expect(firstPrompt?.timestamp != claudeNow)
        #expect(firstPrompt?.timestamp == Date(timeIntervalSince1970: 1_767_603_603.0))
    }

    @Test("the mapper leaves sequence and raw to the tailer")
    func mapperDoesNotStamp() {
        #expect(sessionEvents().allSatisfy { $0.sequence == 0 && $0.raw == nil })
    }

    // MARK: - The subagent transcript

    @Test("a subagent transcript maps like any other, and ends its turn")
    func subagentTranscript() {
        #expect(subagentEvents().kindCounts == [
            "identityUpdated": 4,
            "userPrompt": 1,
            "thinking": 1,
            "assistantText": 1,
            "toolCallStarted": 1,
            "toolCallFinished": 1,
            "usage": 2,
            "turnEnded": 1,
            "textBody": 3
        ])
    }
}

@Suite("ClaudeToolMapping")
struct ClaudeToolMappingTests {
    @Test(
        "tool names map to kinds",
        arguments: [
            ("Bash", ToolKind.shell), ("BashOutput", .shell), ("KillShell", .shell),
            ("Read", .fileRead), ("NotebookRead", .fileRead), ("LS", .fileRead),
            ("Glob", .search), ("Grep", .search), ("ToolSearch", .search),
            ("Write", .fileWrite), ("Edit", .fileWrite), ("MultiEdit", .fileWrite),
            ("NotebookEdit", .fileWrite),
            ("WebFetch", .web), ("WebSearch", .web),
            ("Task", .subagent), ("Agent", .subagent),
            ("EnterPlanMode", .plan), ("ExitPlanMode", .plan), ("TodoWrite", .plan),
            ("mcp__server__tool", .mcp),
            ("Skill", .other), ("SomethingNewInTheNextRelease", .other)
        ]
    )
    func kinds(name: String, expected: ToolKind) {
        #expect(ClaudeToolMapping.resolve(name: name, input: [:]).kind == expected)
    }

    @Test("an MCP target is the server, not the tool")
    func mcpServer() {
        #expect(ClaudeToolMapping.server(inMCPName: "mcp__demo_server__lookup") == "demo_server")
        // A name that only looks like one still yields something usable.
        #expect(ClaudeToolMapping.server(inMCPName: "mcp__solo") == "solo")
        #expect(ClaudeToolMapping.server(inMCPName: "mcp__") == nil)
    }

    @Test("a target is collapsed and truncated for display")
    func targetIsPreviewed() {
        let long = String(repeating: "a", count: 400)
        let resolution = ClaudeToolMapping.resolve(name: "Bash", input: ["command": long])
        #expect(resolution.target?.count == ClaudeToolMapping.targetLimit)

        let multiline = ClaudeToolMapping.resolve(name: "Bash", input: ["command": "cd x\n&& ls"])
        #expect(multiline.target == "cd x && ls")
    }
}

@Suite("ClaudeIdentityFilter")
struct ClaudeIdentityFilterTests {
    @Test("a field is forwarded once, and again only when it changes")
    func collapsesRepeats() {
        var filter = ClaudeIdentityFilter()
        #expect(filter.reduce(SessionIdentityPatch(cwd: "/Users/example/code/demo"))?.cwd
            == "/Users/example/code/demo")
        #expect(filter.reduce(SessionIdentityPatch(cwd: "/Users/example/code/demo")) == nil)
        #expect(filter.reduce(SessionIdentityPatch(cwd: "/Users/example/code/other"))?.cwd
            == "/Users/example/code/other")
    }

    @Test("a patch with one new field forwards only that field")
    func forwardsOnlyTheChange() {
        var filter = ClaudeIdentityFilter()
        _ = filter.reduce(SessionIdentityPatch(cwd: "/a", gitBranch: "main"))
        let second = filter.reduce(SessionIdentityPatch(cwd: "/a", gitBranch: "feature"))
        #expect(second?.gitBranch == "feature")
        #expect(second?.cwd == nil)
    }

    @Test("priming from a seed identity suppresses the first re-announcement")
    func priming() {
        var filter = ClaudeIdentityFilter()
        var identity = SessionIdentity(key: ClaudeFixture.parentKey, sourcePath: "/tmp/x.jsonl")
        identity.cwd = "/Users/example/code/demo"
        filter.prime(with: identity)
        #expect(filter.reduce(SessionIdentityPatch(cwd: "/Users/example/code/demo")) == nil)
    }
}
