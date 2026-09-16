import XCTest
@testable import AgentSessionKit

final class MuseSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = MuseSessionAdapter()
    private let sessionID = "01a0ac0d-5355-7c41-bc77-3b55f0e77ea1"
    /// 2026-01-01T00:00:00Z, in the microseconds Muse stamps records with.
    private let epochMicros: Int64 = 1_767_225_600_000_000

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKMuseSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// One record line, shaped like the CLI writes it.
    private func record(_ payloadType: String, _ payload: [String: Any], at seconds: Int64) -> [String: Any] {
        [
            "schema_version": 1,
            "id": UUID().uuidString.lowercased(),
            "stream": ["kind": "session", "id": sessionID],
            "sequence": seconds,
            "recorded_at": epochMicros + seconds * 1_000_000,
            "record_type": "event",
            "payload_type": payloadType,
            "payload": payload
        ]
    }

    private func runEvent(_ event: [String: Any], at seconds: Int64) -> [String: Any] {
        record("runtime.session", ["kind": "run", "run_id": "run-1", "event": event], at: seconds)
    }

    /// A `retained_frame` line wrapping records as `record_json` strings.
    private func retainedFrame(_ children: [[String: Any]]) throws -> [String: Any] {
        [
            "retained_frame": "session_permission_transaction",
            "frame_schema_version": 1,
            "outer_log_ordinal": 1,
            "transaction_id": "3af0a6dc-0000-0000-0000-000000000000",
            "children": try children.enumerated().map { index, child in
                let data = try JSONSerialization.data(withJSONObject: child, options: [.sortedKeys])
                return ["child_index": index, "record_json": String(decoding: data, as: UTF8.self)]
            }
        ]
    }

    private var conversation: [[String: Any]] {
        get throws {
            [
                record("runtime.session.metadata", [
                    "kind": "metadata",
                    "record": ["workspace_root": "/Users/example/proj", "provider_id": "meta"]
                ], at: 0),
                try retainedFrame([
                    record("runtime.session.permission_format_declared",
                           ["schema_version": 1, "format": "profile_v1"], at: 1)
                ]),
                record("session.name.changed", [
                    "session_id": sessionID, "previous_name": NSNull(), "new_name": "springtime-acrux"
                ], at: 2),
                record("run.model.configured", [
                    "kind": "run_model",
                    "record": ["provider_id": "meta", "model_id": "muse-spark-1.3"]
                ], at: 3),
                runEvent(["kind": "started", "prompt": "Count the lines in NOTES.md"], at: 10),
                runEvent(["kind": "started", "task_id": "01a0ac0d-5905-7f72-94ab-1dd08a3f0e7f"], at: 11),
                runEvent([
                    "kind": "assistant_tool_calls_committed",
                    "tool_calls": [[
                        "id": "fc_1", "call_id": "call_1", "name": "read_file", "args": "{\"offset\":1}"
                    ]]
                ], at: 12),
                runEvent([
                    "kind": "tool_result_batch_committed",
                    "results": [["tool_call_index": 0, "tool_call_id": "call_1", "text": "1|# Notes"]]
                ], at: 13),
                runEvent([
                    "kind": "model_completed",
                    "usage": ["input_tokens": 3173, "output_tokens": 227, "cached_tokens": 2801],
                    "model": "muse-spark-1.3-contributor"
                ], at: 19),
                runEvent([
                    "kind": "assistant_message_committed",
                    "message_id": "8af7d30c-0000-0000-0000-000000000000",
                    "text": "NOTES.md has one line."
                ], at: 20),
                record("session.end", ["kind": "session_end", "record": ["exit_reason": "clean"]], at: 30)
            ]
        }
    }

    /// `~/.local/share/muse/sessions/2026/01/01/<id>/session.jsonl`.
    @discardableResult
    private func writeLog(
        _ lines: [[String: Any]],
        directoryName: String? = nil,
        extraRawLines: [String] = [],
        under parent: URL? = nil
    ) throws -> URL {
        let base = parent ?? home.appendingPathComponent(".local/share/muse/sessions/2026/01/01", isDirectory: true)
        let dir = base.appendingPathComponent(directoryName ?? sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        text.insert(contentsOf: extraRawLines, at: min(4, text.count))
        let url = dir.appendingPathComponent("session.jsonl")
        try (text.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Metadata

    func testMetadataReadsTheRecordLog() throws {
        let url = try writeLog(try conversation)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .muse)
        XCTAssertEqual(summary.harness, .museCode)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        // The model a turn actually completed on wins over the startup choice.
        XCTAssertEqual(summary.model, "muse-spark-1.3-contributor")
        XCTAssertEqual(summary.title, "Count the lines in NOTES.md")
        XCTAssertEqual(summary.summary, "NOTES.md has one line.")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(summary.lastActiveAt, Date(timeIntervalSince1970: 1_767_225_630))
        XCTAssertFalse(summary.hasKnownMessageCount)
        XCTAssertEqual(summary.sourcePath, url.path)
    }

    func testTitleFallsBackToTheSessionNameBeforeAnyPrompt() throws {
        let lines = try conversation.filter { line in
            ((line["payload"] as? [String: Any])?["event"] as? [String: Any])?["prompt"] == nil
        }
        let summary = try adapter.extractMetadata(fileURL: try writeLog(lines))
        XCTAssertEqual(summary.title, "springtime-acrux")
    }

    func testADirectoryNamedAfterAnotherSessionIsRejected() throws {
        let url = try writeLog(try conversation, directoryName: "01a0aaaa-0000-0000-0000-000000000000")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
    }

    func testAnEmptyLogIsUnreadable() throws {
        let url = try writeLog([])
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
    }

    // MARK: - Discovery

    /// Reminder and verifier children keep their own logs inside the parent's
    /// directory; they are part of that conversation, not rows of their own.
    func testDiscoveryListsTopLevelSessionsOnly() throws {
        let parent = try writeLog(try conversation)
        let subagentRoot = parent.deletingLastPathComponent().appendingPathComponent("subagent", isDirectory: true)
        try writeLog(try conversation, directoryName: "a8234fe2-23ee-4cc5-8e81-8908fe89b18d", under: subagentRoot)

        let files = adapter.discoverSessionFiles(homeDirectory: home.path)
        // The temporary directory sits behind `/var → /private/var`.
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [parent.resolvingSymlinksInPath().path])
        XCTAssertEqual(adapter.discoverSessions(homeDirectory: home.path).map(\.sessionID), [sessionID])
    }

    func testRootIsTheMuseSessionsDirectory() {
        XCTAssertEqual(
            adapter.roots(homeDirectory: "/Users/example").map(\.path),
            ["/Users/example/.local/share/muse/sessions"]
        )
    }

    // MARK: - Transcript

    func testTranscriptKeepsTurnsAndToolRoundTripsInOrder() throws {
        let url = try writeLog(try conversation)
        let document = try adapter.parseTranscript(fileURL: url)

        XCTAssertEqual(document.messages.map(\.role), [.user, .tool, .tool, .assistant])
        XCTAssertEqual(document.messages.map(\.text), [
            "Count the lines in NOTES.md",
            "[Tool: read_file]\n{\"offset\":1}",
            "1|# Notes",
            "NOTES.md has one line."
        ])
        XCTAssertEqual(document.messages.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(document.messages.first?.timestamp, Date(timeIntervalSince1970: 1_767_225_610))
    }

    func testRetainedFrameChildrenReachTheTranscript() throws {
        var lines = try conversation
        let index = try XCTUnwrap(lines.firstIndex { line in
            ((line["payload"] as? [String: Any])?["event"] as? [String: Any])?["prompt"] != nil
        })
        lines[index] = try retainedFrame([lines[index]])
        let document = try adapter.parseTranscript(fileURL: try writeLog(lines))
        XCTAssertEqual(document.messages.first?.text, "Count the lines in NOTES.md")
    }

    func testMalformedLinesAreSkipped() throws {
        let url = try writeLog(try conversation, extraRawLines: ["{not json", "[]", ""])
        XCTAssertEqual(try adapter.parseTranscript(fileURL: url).messages.count, 4)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, sessionID)
    }

    // MARK: - Deletion, registry, resume

    func testDeletionIsRefused() throws {
        let summary = try adapter.extractMetadata(fileURL: try writeLog(try conversation))
        XCTAssertFalse(SessionProvider.muse.supportsDeletion)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.muse))
        }
    }

    func testStandardRegistryCarriesTheAdapter() {
        let registry = SessionProviderRegistry.standard(homeDirectory: "/Users/example")
        XCTAssertTrue(registry.adapter(for: .muse) is MuseSessionAdapter)
        XCTAssertEqual(SessionProvider.muse.defaultHarness, .museCode)
    }

    func testResumeCommand() throws {
        XCTAssertEqual(
            try SessionResumeCommandBuilder.command(provider: .muse, sessionID: sessionID),
            "muse resume \(sessionID)"
        )
    }

    func testMicrosecondEpochsParse() {
        XCTAssertEqual(SessionParsing.date(NSNumber(value: epochMicros)), Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(SessionParsing.date(NSNumber(value: 1_767_225_600_000)), Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(SessionParsing.date(NSNumber(value: 1_767_225_600)), Date(timeIntervalSince1970: 1_767_225_600))
    }
}
