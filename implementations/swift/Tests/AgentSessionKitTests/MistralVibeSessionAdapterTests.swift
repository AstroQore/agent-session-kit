import XCTest
@testable import AgentSessionKit

final class MistralVibeSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = MistralVibeSessionAdapter()
    private let sessionID = "5c0ffee1-7a1b-4c2d-8e3f-0123456789ab"
    private var directoryName: String { "session_20260101_000000_5c0ffee1" }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKMistralVibeSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private var root: URL { home.appendingPathComponent(".vibe/logs/session", isDirectory: true) }

    /// `meta.json` shaped like `vibe` 2.x writes it, minus the bulk.
    private func meta(
        id: String? = nil,
        title: Any = NSNull(),
        activeModel: String = "mistral-medium-3.5",
        totalMessages: Int = 5
    ) -> [String: Any] {
        [
            "session_id": id ?? sessionID,
            "parent_session_id": NSNull(),
            "start_time": "2026-01-01T00:00:00.250000+00:00",
            "end_time": "2026-01-01T00:03:30.500000+00:00",
            "git_commit": NSNull(),
            "git_branch": NSNull(),
            "environment": ["working_directory": "/Users/example/proj"],
            "origin_directory": "/Users/example/proj",
            "username": "example",
            "child_sessions": [],
            "loops": [],
            "title": title,
            "title_source": "auto",
            "config": [
                "active_model": activeModel,
                "models": [
                    "mistral-medium-3.5": [
                        "name": "mistral-vibe-cli-latest", "provider": "mistral", "alias": "mistral-medium-3.5",
                        "input_price": 1.5, "output_price": 7.5
                    ],
                    "local": ["name": "devstral", "provider": "llamacpp", "alias": "local"]
                ]
            ],
            "stats": ["session_prompt_tokens": 1_200, "session_completion_tokens": 80, "session_cost": 0.0024],
            "total_messages": totalMessages,
            "system_prompt": ["role": "system", "content": "You are Vibe."]
        ]
    }

    private var conversation: [[String: Any]] {
        [
            ["role": "user", "content": "Count the lines in NOTES.md", "injected": false, "message_id": "m-1"],
            [
                "role": "assistant", "content": "I'll read it.", "injected": false, "message_id": "m-2",
                "reasoning_content": "private reasoning",
                "tool_calls": [[
                    "id": "call_1", "index": 0, "type": "function",
                    "function": ["name": "read_file", "arguments": "{\"path\":\"NOTES.md\"}"]
                ]]
            ],
            [
                "role": "tool", "content": "1|# Notes", "injected": false, "name": "read_file",
                "tool_call_id": "call_1", "tool_result": ["output": ["content": "1|# Notes"], "cancelled": false]
            ],
            [
                "role": "user", "content": "Summary of the conversation so far", "injected": true,
                "context_boundary": "compaction"
            ],
            [
                "role": "assistant",
                "content": [["type": "text", "text": "NOTES.md has one line."]],
                "injected": false, "message_id": "m-3"
            ]
        ]
    }

    @discardableResult
    private func writeSession(
        meta: [String: Any]? = nil,
        messages: [[String: Any]]? = nil,
        rawLines: [String] = [],
        directoryName: String? = nil,
        under parent: URL? = nil
    ) throws -> URL {
        let directory = (parent ?? root).appendingPathComponent(directoryName ?? self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metaData = try JSONSerialization.data(withJSONObject: meta ?? self.meta(), options: [.prettyPrinted])
        try metaData.write(to: directory.appendingPathComponent("meta.json"))
        var lines = try (messages ?? conversation).map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        lines.insert(contentsOf: rawLines, at: min(1, lines.count))
        let url = directory.appendingPathComponent("messages.jsonl")
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Discovery

    /// A sub-agent's session nests under its parent's `agents/`; lease files
    /// and Vibe's own listing cache sit beside the sessions. None is a row.
    func testDiscoveryListsTopLevelSessionsOnly() throws {
        let parent = try writeSession()
        try writeSession(
            meta: meta(id: "a8234fe2-23ee-4cc5-8e81-8908fe89b18d"),
            directoryName: "explore_20260101_000100_a8234fe2",
            under: parent.deletingLastPathComponent().appendingPathComponent("agents", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("active"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("active/\(sessionID).lock"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(".session_index.json"))
        // A directory with no meta.json is an interrupted first save, not a session.
        let orphan = root.appendingPathComponent("session_20260101_000200_ffffffff", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data().write(to: orphan.appendingPathComponent("messages.jsonl"))

        let files = adapter.discoverSessionFiles(homeDirectory: home.path)
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [parent.resolvingSymlinksInPath().path])
        XCTAssertEqual(adapter.discoverSessions(homeDirectory: home.path).map(\.sessionID), [sessionID])
    }

    func testDiscoveryToleratesAMissingRootAndSkipsSymlinks() throws {
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path), [])

        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        let real = try writeSession(under: elsewhere)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(directoryName),
            withDestinationURL: real.deletingLastPathComponent()
        )
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path), [])
    }

    func testRootIsTheVibeSessionLogDirectory() {
        XCTAssertEqual(adapter.roots(homeDirectory: "/Users/example").map(\.path),
                       ["/Users/example/.vibe/logs/session"])
    }

    // MARK: - Metadata

    func testMetadataReadsMetaAndTheLog() throws {
        let url = try writeSession()
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .mistralVibe)
        XCTAssertEqual(summary.harness, .mistralVibe)
        XCTAssertEqual(summary.sessionID, sessionID)
        // The alias resolves to the model id the session actually calls.
        XCTAssertEqual(summary.model, "mistral-vibe-cli-latest")
        // No title recorded: the first prompt a person typed.
        XCTAssertEqual(summary.title, "Count the lines in NOTES.md")
        XCTAssertEqual(summary.summary, "NOTES.md has one line.")
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        let created = try XCTUnwrap(summary.createdAt)
        XCTAssertEqual(created.timeIntervalSince1970, 1_767_225_600.25, accuracy: 0.001)
        let active = try XCTUnwrap(summary.lastActiveAt)
        XCTAssertEqual(active.timeIntervalSince1970, 1_767_225_810.5, accuracy: 0.001)
        XCTAssertEqual(summary.sourcePath, url.path)
        XCTAssertEqual(summary.sizeBytes, SessionParsing.fileSize(url))
        XCTAssertFalse(summary.hasKnownMessageCount)
    }

    func testARecordedTitleWins() throws {
        let url = try writeSession(meta: meta(title: "Notes line count"))
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title, "Notes line count")
    }

    func testAnInjectedFirstLineIsNotTheTitle() throws {
        var messages = conversation
        messages.insert(["role": "user", "content": "<plan>resumed</plan>", "injected": true], at: 0)
        let url = try writeSession(messages: messages)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title, "Count the lines in NOTES.md")
    }

    /// An alias with no entry in `models` is not guessed at.
    func testAnUnknownAliasYieldsNoModel() throws {
        XCTAssertNil(try adapter.extractMetadata(fileURL: try writeSession(meta: meta(activeModel: "retired"))).model)
        XCTAssertEqual(
            MistralVibeSessionAdapter.model(in: [
                "active_model": "fast",
                "models": [["alias": "fast", "name": "mistral-small-latest"]]
            ]),
            "mistral-small-latest"
        )
    }

    func testADirectoryNamedAfterAnotherSessionIsRejected() throws {
        let url = try writeSession(directoryName: "session_20260101_000000_ffffffff")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.invalidFormat = error else { return XCTFail("got \(error)") }
        }
    }

    func testMissingOrMalformedMetaIsUnreadable() throws {
        let url = try writeSession()
        try Data("{not json".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.unreadable = error else { return XCTFail("got \(error)") }
        }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
    }

    /// Vibe refuses an empty log unless the session recorded no messages.
    func testAnEmptyLogListsOnlyWhenMetaSaysItIsEmpty() throws {
        let interrupted = try writeSession(messages: [])
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: interrupted))

        let rewound = try writeSession(meta: meta(totalMessages: 0), messages: [])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: rewound).sessionID, sessionID)
        XCTAssertEqual(try adapter.parseTranscript(fileURL: rewound).messages, [])
    }

    // MARK: - Transcript

    func testTranscriptKeepsTurnsAndToolRoundTripsAndDropsInjectedLines() throws {
        let document = try adapter.parseTranscript(fileURL: try writeSession())

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        XCTAssertEqual(document.messages.map(\.text), [
            "Count the lines in NOTES.md",
            "I'll read it.",
            "[Tool: read_file]\n{\"path\":\"NOTES.md\"}",
            "1|# Notes",
            "NOTES.md has one line."
        ])
        XCTAssertEqual(document.messages.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertTrue(document.messages.allSatisfy { $0.timestamp == nil })
        XCTAssertFalse(document.messages.contains { $0.text.contains("private reasoning") })
    }

    func testMalformedLinesAreSkipped() throws {
        let url = try writeSession(rawLines: ["{not json", "[]", "\"text\""])
        XCTAssertEqual(try adapter.parseTranscript(fileURL: url).messages.count, 5)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, sessionID)
    }

    // MARK: - Change fingerprint

    /// A rename rewrites only `meta.json`; the row still has to refresh.
    func testChangeFingerprintFoldsInMeta() throws {
        let url = try writeSession()
        let before = try XCTUnwrap(adapter.changeFingerprint(fileURL: url))
        XCTAssertEqual(before.size,
                       SessionParsing.fileSize(url) + SessionParsing.fileSize(url.deletingLastPathComponent()
                           .appendingPathComponent("meta.json")))

        let metaData = try JSONSerialization.data(withJSONObject: meta(title: "A much longer manual title"), options: [])
        try metaData.write(to: url.deletingLastPathComponent().appendingPathComponent("meta.json"))
        XCTAssertNotEqual(adapter.changeFingerprint(fileURL: url), before)
        XCTAssertNil(adapter.changeFingerprint(fileURL: root.appendingPathComponent("gone/messages.jsonl")))
    }

    // MARK: - Deletion, registry, resume

    func testDeletionIsRefused() throws {
        let summary = try adapter.extractMetadata(fileURL: try writeSession())
        XCTAssertFalse(SessionProvider.mistralVibe.supportsDeletion)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.mistralVibe))
        }
    }

    func testStandardRegistryCarriesTheAdapter() {
        let registry = SessionProviderRegistry.standard(homeDirectory: "/Users/example")
        XCTAssertTrue(registry.adapter(for: .mistralVibe) is MistralVibeSessionAdapter)
        XCTAssertEqual(SessionProvider.mistralVibe.defaultHarness, .mistralVibe)
    }

    func testResumeCommand() throws {
        XCTAssertEqual(
            try SessionResumeCommandBuilder.command(provider: .mistralVibe, sessionID: sessionID),
            "vibe --resume \(sessionID)"
        )
    }
}
