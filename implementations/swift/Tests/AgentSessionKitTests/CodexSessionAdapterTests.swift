import SQLite3
import XCTest
@testable import AgentSessionKit

final class CodexSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let sessionID = "019c2215-0f3c-7f72-89e3-92598c209589"

    private var adapter: CodexSessionAdapter { CodexSessionAdapter(homeDirectory: home.path) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKCodexSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<stamp>-<uuid>.jsonl`.
    @discardableResult
    private func writeRollout(
        lines: [String],
        root: String = ".codex/sessions",
        fileID: String? = nil
    ) throws -> URL {
        let directory = home
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent("2026/02/03", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "rollout-2026-02-03T13-58-51-\(fileID ?? sessionID).jsonl"
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func metaLine(id: String? = nil, originator: String? = "codex_cli_rs") -> String {
        let originatorField = originator.map { "\"originator\":\"\($0)\"," } ?? ""
        return """
        {"timestamp":"2026-02-03T05:58:51.452Z","type":"session_meta","payload":\
        {"id":"\(id ?? sessionID)","timestamp":"2026-02-03T05:58:51.452Z","cwd":"/Users/example/proj",\
        \(originatorField)"cli_version":"0.0.0","source":"cli","model_provider":"openai"}}
        """
    }

    private func autoReviewMetaLine(parentSessionID: String) -> String {
        """
        {"timestamp":"2026-02-03T05:58:51.452Z","type":"session_meta","payload":\
        {"id":"\(sessionID)","session_id":"\(parentSessionID)",\
        "parent_thread_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",\
        "timestamp":"2026-02-03T05:58:51.452Z","cwd":"/Users/example/proj",\
        "originator":"Codex Desktop","source":{"subagent":{"other":"guardian"}},\
        "thread_source":"subagent","model_provider":"openai"}}
        """
    }

    private func turnContextLine(model: String) -> String {
        """
        {"timestamp":"2026-02-03T05:58:52.000Z","type":"turn_context","payload":\
        {"turn_id":"01a01124-c7c7-7b91-9774-94c735dae055","cwd":"/Users/example/proj",\
        "model":"\(model)","effort":"xhigh","summary":"auto"}}
        """
    }

    private func userMessageLine(_ text: String, timestamp: String = "2026-02-03T05:59:00.000Z") -> String {
        """
        {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user",\
        "content":[{"type":"input_text","text":\(JSONFixture.string(text))}]}}
        """
    }

    private var rolloutLines: [String] {
        [
            metaLine(),
            userMessageLine("Add the session list"),
            """
            {"timestamp":"2026-02-03T05:59:05.000Z","type":"response_item","payload":{"type":"reasoning",\
            "summary":[],"encrypted_content":"REDACTED"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:06.000Z","type":"response_item","payload":{"type":"message",\
            "role":"assistant","content":[{"type":"output_text","text":"Working on it."}]}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:07.000Z","type":"response_item","payload":{"type":"function_call",\
            "name":"shell","arguments":"{}","call_id":"call_1"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:08.000Z","type":"response_item","payload":\
            {"type":"function_call_output","call_id":"call_1","output":"exit 0"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:09.000Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":10,"output_tokens":2}}}}
            """
        ]
    }

    // MARK: - Metadata

    func testMetadataComesFromTheSessionMetaHeader() throws {
        let url = try writeRollout(lines: rolloutLines)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .codex)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.title, "Add the session list")
        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.kitTest.date(from: "2026-02-03T05:58:51.452Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.kitTest.date(from: "2026-02-03T05:59:09.000Z"))
        XCTAssertEqual(summary.messageCount, rolloutLines.count)
    }

    func testBoundedMetadataDefersInsteadOfOverwritingACompleteHeader() async throws {
        let instructions = String(repeating: "x", count: 300 * 1024)
        let header = autoReviewMetaLine(parentSessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            .replacingOccurrences(of: "\"model_provider\":\"openai\"",
                                  with: "\"base_instructions\":\"\(instructions)\",\"model_provider\":\"openai\"")
        let lines = [header, turnContextLine(model: "fixture-model"), userMessageLine("Find the active session")]
        let url = try writeRollout(lines: lines)

        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url, headByteLimit: 256 * 1024)) {
            XCTAssertTrue($0 is SessionIndexReadDeferred)
        }
        let (service, store) = try makeIndex()
        await service.refreshIndex()
        let initial = try await store.allSummaries()
        let original = try XCTUnwrap(initial.first)
        XCTAssertEqual(original.projectDir, "/Users/example/proj")
        XCTAssertNotNil(original.providerVariant)

        _ = try writeRollout(lines: lines + [userMessageLine("Append after a large header", timestamp: "2026-02-03T06:00:00.000Z")])
        let locator = URL(fileURLWithPath: original.sourcePath)
        let result = await service.refreshIndexCandidates([.init(provider: .codex, url: locator)], budget: Self.budget)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(result.written, 0)
        XCTAssertEqual(result.parsed, 0)
        let unchanged = try await store.allSummaries()
        XCTAssertEqual(unchanged, initial)

        let full = await service.refreshIndexFully()
        XCTAssertEqual(full.written, 1)
        let updated = try await store.allSummaries()
        XCTAssertEqual(updated.first?.lastActiveAt, ISO8601DateFormatter.kitTest.date(from: "2026-02-03T06:00:00.000Z"))
        XCTAssertEqual(updated.first?.providerVariant, original.providerVariant)
    }

    // MARK: - Harness

    /// Every Codex surface writes into the same rollout tree, and exactly one
    /// `originator` is not Codex. Anything unrecognised — including a header
    /// with no originator at all — stays on Codex rather than being invented
    /// as ChatGPT Work usage.
    func testTheOriginatorDecidesCodexVersusChatGPTWork() throws {
        let cases: [(originator: String?, expected: Harness)] = [
            ("codex_work_desktop", .chatgptWork),
            ("Codex Desktop", .codex),
            ("codex-tui", .codex),
            ("codex_cli_rs", .codex),
            ("codex_exec", .codex),
            ("codex_vscode", .codex),
            ("something_new", .codex),
            (nil, .codex)
        ]
        for (originator, expected) in cases {
            let url = try writeRollout(lines: [
                metaLine(originator: originator),
                userMessageLine("Hello")
            ])
            XCTAssertEqual(
                try adapter.extractMetadata(fileURL: url).harness,
                expected,
                "originator \(originator ?? "<absent>")"
            )
        }
    }

    /// The session list and the cost ledger must agree about which rollout is
    /// ChatGPT Work, so both go through the one mapping.
    func testTheHarnessMappingIsTheCostScannersOwn() {
        for originator in ["codex_work_desktop", "Codex Desktop", nil] {
            XCTAssertEqual(
                CodexOriginator.harness(originator: originator),
                originator == CodexOriginator.chatgptWork ? .chatgptWork : .codex
            )
        }
    }

    func testGuardianRolloutCarriesItsOriginalSessionRelationship() throws {
        let parent = "aaaaaaaa-1111-2222-3333-444444444444"
        let url = try writeRollout(lines: [
            autoReviewMetaLine(parentSessionID: parent),
            turnContextLine(model: "codex-auto-review"),
            userMessageLine("Review the proposed changes")
        ])

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.model, "codex-auto-review")
        XCTAssertEqual(
            CodexSessionAdapter.autoReviewParentSessionID(
                providerVariant: summary.providerVariant
            ),
            parent
        )
    }

    func testOrdinarySubagentDoesNotPretendToBeAutoReview() throws {
        let url = try writeRollout(lines: [metaLine(), userMessageLine("Implement the task")])
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertNil(
            CodexSessionAdapter.autoReviewParentSessionID(
                providerVariant: summary.providerVariant
            )
        )
    }

    // MARK: - Model

    func testTheModelComesFromTheTurnContext() throws {
        let url = try writeRollout(lines: [
            metaLine(),
            turnContextLine(model: "gpt-daybreak-blue-latest"),
            userMessageLine("Hello")
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).model, "gpt-daybreak-blue-latest")
    }

    /// Older rollouts stamped the model inside the token-count event instead.
    func testTheModelFallsBackToTheTokenCountInfo() throws {
        let url = try writeRollout(lines: [
            metaLine(),
            userMessageLine("Hello"),
            """
            {"timestamp":"2026-02-03T05:59:09.000Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"model":"gpt-5-codex","total_token_usage":{"input_tokens":10,"output_tokens":2}}}}
            """
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).model, "gpt-5-codex")
    }

    func testARolloutThatNamesNoModelKeepsItNil() throws {
        let url = try writeRollout(lines: [metaLine(), userMessageLine("Hello")])
        XCTAssertNil(try adapter.extractMetadata(fileURL: url).model)
    }

    func testFilenameAndHeaderIdMismatchIsRejected() throws {
        let url = try writeRollout(
            lines: rolloutLines,
            fileID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        // A rejected file also drops out of the summarized sweep instead
        // of failing the whole discovery pass.
        XCTAssertTrue(adapter.discoverSessions(homeDirectory: home.path).isEmpty)
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 1)
    }

    func testFilenameUUIDIsUsedWhenTheHeaderHasNoId() throws {
        let url = try writeRollout(lines: [
            "{\"timestamp\":\"2026-02-03T05:58:51.452Z\",\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/example/proj\"}}",
            userMessageLine("Hello")
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, sessionID)
    }

    func testIDEContextEnvelopeIsStrippedFromTheDerivedTitle() throws {
        let prompt = """
        # Context from my IDE setup:
        The user is working in VS Code. Open file: Sources/Thing.swift
        Selected text: struct Thing {}

        ## My request for Codex:
        Rename Thing to Widget
        """
        let url = try writeRollout(lines: [metaLine(), userMessageLine(prompt)])
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.title, "Rename Thing to Widget")
        XCTAssertEqual(summary.summary, "Rename Thing to Widget")
    }

    func testPromptWithoutTheEnvelopeIsLeftAlone() {
        XCTAssertEqual(CodexSessionAdapter.strippingIDEEnvelope("## My request for Codex: inline"),
                       "## My request for Codex: inline")
    }

    func testArchivedSessionsAreDiscovered() throws {
        let live = try writeRollout(lines: rolloutLines)
        let archived = try writeRollout(
            lines: [metaLine(id: "019c2215-0f3c-7f72-89e3-92598c209590"), userMessageLine("Archived")],
            root: ".codex/archived_sessions",
            fileID: "019c2215-0f3c-7f72-89e3-92598c209590"
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(live), SessionTestPaths.canonical(archived)])
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 2)
    }

    /// Codex's `local_thread_store_compression` renames a week-old rollout
    /// to `.jsonl.zst`. It must stay listed, keep its id, and read the same.
    func testCompressedRolloutsAreDiscoveredAndRead() throws {
        let directory = home.appendingPathComponent(".codex/sessions/2026/02/03", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-02-03T13-58-51-\(sessionID).jsonl.zst")
        try ZstdTestFrame.cliCompressedRollout.write(to: url)

        let found = adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical)
        XCTAssertEqual(found, [SessionTestPaths.canonical(url)])

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.summary, "Add the session list")
        XCTAssertEqual(summary.sourcePath, url.path)
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertEqual(summary.sizeBytes, Int64(ZstdTestFrame.cliCompressedRollout.count), "size is the on-disk size")

        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.map(\.text), ["Add the session list", "Working on it."])

        let plan = try adapter.deletionPlan(for: summary, homeDirectory: home.path)
        XCTAssertEqual(plan.pathsToRemove, [url.path])
    }

    func testIndexMigratesAnArchiveAndFullRefreshCompletesPartialMetadata() async throws {
        let parent = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let lines = [autoReviewMetaLine(parentSessionID: parent)] + rolloutLines.dropFirst()
        let plain = try writeRollout(lines: lines)
        let (service, store) = try makeIndex()
        await service.refreshIndex()
        let summaries = try await store.allSummaries()
        let prior = try XCTUnwrap(summaries.first)
        XCTAssertEqual(prior.providerVariant, CodexSessionAdapter.autoReviewVariantPrefix + parent)
        let priorCursor = try await store.fileCursor(pathHash: SessionIndexService.pathHash(prior.sourcePath))

        let archive = plain.appendingPathExtension("zst")
        try ZstdTestFrame.write(try Data(contentsOf: plain), to: archive)
        let bothPaths = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(bothPaths.written, 0)
        XCTAssertEqual(bothPaths.deferred, 1)
        let duringConversion = try await store.allSummaries()
        XCTAssertEqual(duringConversion, summaries)

        try Data("interrupted archive write".utf8).write(to: archive)
        try FileManager.default.removeItem(at: plain)
        let incomplete = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(incomplete.written, 0)
        XCTAssertEqual(incomplete.pruned, 0)
        let retained = try await store.allSummaries()
        XCTAssertEqual(retained, summaries)

        try ZstdTestFrame.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: archive)
        let archiveTime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: archiveTime], ofItemAtPath: archive.path)

        let converted = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertTrue(converted.completedDiscovery)
        XCTAssertEqual(converted.written, 1)
        let convertedRows = try await store.allSummaries()
        XCTAssertEqual(convertedRows.count, 1)
        let migrated = try XCTUnwrap(convertedRows.first)
        XCTAssertEqual(migrated.sessionID, prior.sessionID)
        XCTAssertEqual(migrated.providerVariant, prior.providerVariant)
        XCTAssertEqual(migrated.harness, prior.harness)
        XCTAssertEqual(migrated.title, prior.title)
        XCTAssertEqual(migrated.projectDir, prior.projectDir)
        XCTAssertEqual(migrated.lastActiveAt, prior.lastActiveAt)
        XCTAssertEqual(SessionTestPaths.canonical(URL(fileURLWithPath: migrated.sourcePath)), SessionTestPaths.canonical(archive))
        let migratedCursor = try await store.fileCursor(pathHash: SessionIndexService.pathHash(migrated.sourcePath))
        XCTAssertEqual(migratedCursor?.sessionRow, priorCursor?.sessionRow)
        XCTAssertTrue(migratedCursor?.requiresFullRefresh == true)
        let hits = try await service.search("Add the session list")
        XCTAssertEqual(hits.first?.summary.sourcePath, migrated.sourcePath)

        let candidate = SessionIndexCandidate(provider: .codex, url: URL(fileURLWithPath: migrated.sourcePath))
        let idle = await service.refreshIndexCandidates([candidate], budget: Self.budget)
        XCTAssertEqual(idle.written, 0)
        XCTAssertEqual(idle.parsed, 0)

        let full = await service.refreshIndexFully()
        XCTAssertEqual(full.written, 1)
        let completeCursor = try await store.fileCursor(pathHash: SessionIndexService.pathHash(migrated.sourcePath))
        XCTAssertFalse(completeCursor?.requiresFullRefresh == true)
        let secondFull = await service.refreshIndexFully()
        XCTAssertEqual(secondFull.written, 0)
    }

    func testNewCompressedSourceUsesEventTimeAndIndexesAutomatically() async throws {
        let plain = try writeRollout(lines: rolloutLines)
        let archive = plain.appendingPathExtension("zst")
        try ZstdTestFrame.write(try Data(contentsOf: plain), to: archive)
        try FileManager.default.removeItem(at: plain)
        let archiveTime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: archiveTime], ofItemAtPath: archive.path)
        let (service, store) = try makeIndex()
        let indexed = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(indexed.written, 1)
        let rows = try await store.allSummaries()
        XCTAssertEqual(rows.map(\.sessionID), [sessionID])
        XCTAssertEqual(rows.first?.lastActiveAt,
                       ISO8601DateFormatter.kitTest.date(from: "2026-02-03T05:59:09.000Z"))
    }

    func testDeletingOrResettingIndexEntriesClearsPartialMarkers() async throws {
        let plain = try writeRollout(lines: rolloutLines)
        let archive = plain.appendingPathExtension("zst")
        try ZstdTestFrame.write(try Data(contentsOf: plain), to: archive)
        try FileManager.default.removeItem(at: plain)
        let (service, store) = try makeIndex()

        _ = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(try partialMarkerCount(), 1)
        try await store.resetFileCursors()
        XCTAssertEqual(try partialMarkerCount(), 0)

        _ = await service.refreshIndexBatch(budget: Self.budget)
        let rows = try await store.allSummaries()
        XCTAssertEqual(try partialMarkerCount(), 1)
        try await store.removeSessions(sourcePathIn: rows.map(\.sourcePath))
        XCTAssertEqual(try partialMarkerCount(), 0)

        _ = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(try partialMarkerCount(), 1)
        try await store.eraseAll()
        XCTAssertEqual(try partialMarkerCount(), 0)

        _ = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(try partialMarkerCount(), 1)
        try FileManager.default.removeItem(at: archive)
        let pruned = await service.refreshIndexBatch(budget: Self.budget)
        XCTAssertEqual(pruned.pruned, 1)
        XCTAssertEqual(try partialMarkerCount(), 0)
    }

    private func partialMarkerCount() throws -> Int {
        var database: OpaquePointer?
        let path = home.appendingPathComponent("test-index.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM session_index_meta WHERE key GLOB 'partial_metadata:*'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static let budget = SessionIndexRefreshBudget(
        maxFiles: 2, maxBytes: 16 * 1024 * 1024, maxFileBytes: 9 * 1024 * 1024
    )

    private func makeIndex() throws -> (SessionIndexService, SessionIndexStore) {
        let store = try SessionIndexStore(url: home.appendingPathComponent("test-index.sqlite"))
        let service = SessionIndexService(
            homeDirectory: home.path, store: store,
            registry: SessionProviderRegistry(adapters: [FixtureIndexAdapter(inner: adapter)]),
            bodyIndexing: { true }
        )
        return (service, store)
    }

    func testCompressedRolloutWithMismatchedFilenameIsRefused() throws {
        let directory = home.appendingPathComponent(".codex/sessions/2026/02/03", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209590.jsonl.zst")
        try ZstdTestFrame.cliCompressedRollout.write(to: url)
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
    }

    func testDiscoveryToleratesMissingDirectories() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
    }

    func testTrailingUUIDParsing() {
        XCTAssertEqual(
            CodexSessionAdapter.trailingUUID(in: "rollout-2026-02-03T13-58-51-\(sessionID)"),
            sessionID
        )
        XCTAssertNil(CodexSessionAdapter.trailingUUID(in: "rollout-2026-02-03T13-58-51"))
        XCTAssertNil(CodexSessionAdapter.trailingUUID(in: "rollout-not-a-uuid-here-at-all-zzzzzzzzzzzz"))
    }

    // MARK: - Transcript

    func testTranscriptKeepsOnlyResponseItems() throws {
        let url = try writeRollout(lines: rolloutLines)
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .tool, .tool])
        XCTAssertEqual(document.messages.map(\.text), [
            "Add the session list",
            "Working on it.",
            "[Tool: shell]\n{}",
            "exit 0"
        ])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertFalse(document.truncated)
    }

    func testTranscriptHonorsARange() throws {
        let url = try writeRollout(lines: rolloutLines)
        let document = try adapter.parseTranscript(fileURL: url, range: 0..<2)
        XCTAssertEqual(document.messages.map(\.text), ["Add the session list", "Working on it."])
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.totalMessageCount, 4)
    }

    // MARK: - Deletion plan

    func testDeletionPlanIsTheRolloutFileAlone() throws {
        let url = try writeRollout(lines: rolloutLines)
        let summary = try adapter.extractMetadata(fileURL: url)
        let plan = try adapter.deletionPlan(for: summary, homeDirectory: home.path)

        XCTAssertEqual(plan.pathsToRemove, [url.path])
        XCTAssertEqual(plan.validationSourcePath, url.path)
        XCTAssertEqual(plan.expectedSessionID, sessionID)
    }

    // MARK: - Hydration wiring

    func testTitleFromTheStateDatabaseOverridesTheFirstPrompt() throws {
        let url = try writeRollout(lines: rolloutLines)
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Session manager work", cwd: "/Users/example/other")]
        )
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title, "Session manager work")
    }
}

enum JSONFixture {
    /// JSON-encode a Swift string, quotes included, so fixture literals
    /// can embed newlines and punctuation safely.
    static func string(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        var text = String(decoding: data, as: UTF8.self)
        text.removeFirst()
        text.removeLast()
        return text
    }
}

/// The test archives are small. Production adapters also limit the
/// decoded transcript; this fixture exercises metadata and cursor routing.
private struct FixtureIndexAdapter: SessionProviderAdapter {
    let inner: CodexSessionAdapter
    var provider: SessionProvider { inner.provider }

    func roots(homeDirectory: String) -> [URL] { inner.roots(homeDirectory: homeDirectory) }
    func discoverSessionFiles(homeDirectory: String) -> [URL] { inner.discoverSessionFiles(homeDirectory: homeDirectory) }
    func extractMetadata(fileURL: URL) throws -> SessionSummary { try inner.extractMetadata(fileURL: fileURL) }

    func boundedIndexReadPlan(fileURL: URL, sourceBytes: Int64, indexBodies: Bool) -> SessionIndexReadPlan? {
        SessionIndexReadPlan(estimatedBytes: 512 * 1024, requiresFullRefresh: CodexRolloutFile.isCompressed(fileURL)) {
            try inner.extractMetadata(fileURL: fileURL, headByteLimit: 256 * 1024)
        }
    }

    func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        try inner.parseTranscript(fileURL: fileURL, range: range)
    }

    func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        try inner.deletionPlan(for: summary, homeDirectory: homeDirectory)
    }
}
