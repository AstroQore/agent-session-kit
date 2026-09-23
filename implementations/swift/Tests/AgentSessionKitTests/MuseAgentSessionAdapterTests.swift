import XCTest
@testable import AgentSessionKit

final class MuseAgentSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = MuseAgentSessionAdapter()

    /// 2026-01-01T00:00:00Z as seconds since the Apple reference date — the
    /// clock the client writes. As Unix seconds it would be 1995.
    private let referenceStart: Double = 788_918_400
    private let unixStart: Double = 1_767_225_600

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKMuseAgentAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var storeDirectory: URL {
        home.appendingPathComponent(MuseAgentSessionAdapter.storeRelativePath, isDirectory: true)
    }

    // MARK: - Fixtures

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = storeDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func write(_ name: String, messages: [[String: Any]]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: messages)
        let url = storeDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func message(
        _ id: String,
        user: Bool,
        content: String,
        at offset: Double,
        seq: Int?,
        streaming: Bool = false,
        blocks: [[String: Any]]? = nil
    ) -> [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "isUser": user,
            "content": content,
            "timestamp": referenceStart + offset,
            "isStreaming": streaming,
            "contentBlocks": blocks ?? (content.isEmpty ? [] : [["markdown": ["text": content, "inlineEntities": []]]]),
            "sources": [],
            "mentions": [],
            "inlineEntities": [],
            "activeToolCalls": [],
            "hatchVMName": "vm-synthetic",
            "rawUnifiedResponse": "{\"__typename\":\"Synthetic\"}"
        ]
        if let seq { out["sortSeq"] = seq }
        return out
    }

    /// The main chat, written out of order on purpose: `sortSeq` is the order.
    @discardableResult
    private func writeMainChat() throws -> URL {
        try write("hatch-main.json", messages: [
            message("m2", user: false, content: "", at: 60, seq: 2, blocks: [
                ["thinkingStatus": ["text": "Thinking"]],
                ["markdown": ["text": "Three steps.", "inlineEntities": []]],
                ["optionWidget": ["options": ["a", "b"]]],
                ["markdown": ["text": "First, read the notes.", "inlineEntities": []]]
            ]),
            message("m1", user: true, content: "Plan the week for the garden club.", at: 0, seq: 1),
            message("m3", user: true, content: "Pick option a.", at: 120, seq: 3),
            message("m4", user: false, content: "Done: option a is booked.", at: 180, seq: 4),
            // A reply still streaming, with nothing in it yet.
            message("m5", user: false, content: "", at: 240, seq: 5, streaming: true)
        ])
    }

    // MARK: - Discovery

    func testRootIsExactlyTheConversationCache() {
        XCTAssertEqual(
            adapter.roots(homeDirectory: "/Users/example").map(\.path),
            ["/Users/example/Library/Caches/ConversationCache"]
        )
    }

    /// Meta AI.app writes UUID-named chats into the same directory; only
    /// `hatch-*.json` is Muse's.
    func testDiscoveryListsOnlyHatchFiles() throws {
        try writeMainChat()
        try write("hatch-side_2.json", "[]")
        try write("0ca942de-1111-2222-3333-444444444444.json", "[]")
        try write(".cache_version", "12")
        try write(".user_id", "synthetic")
        try write("hatch-.json", "[]")
        try write("hatch-bad name.json", "[]")
        try write("hatch-main.txt", "[]")
        try write("main.json", "[]")
        let nested = storeDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "[]".write(to: nested.appendingPathComponent("hatch-deep.json"), atomically: true, encoding: .utf8)
        let outside = home.appendingPathComponent("outside.json")
        try "[]".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: storeDirectory.appendingPathComponent("hatch-link.json"), withDestinationURL: outside
        )

        let found = adapter.discoverSessionFiles(homeDirectory: home.path).map(\.lastPathComponent)
        XCTAssertEqual(found, ["hatch-main.json", "hatch-side_2.json"])
    }

    func testMissingStoreDiscoversNothing() throws {
        try FileManager.default.removeItem(at: storeDirectory)
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path), [])
    }

    func testSessionIDIsTheFileStem() {
        let dir = URL(fileURLWithPath: "/Users/example/Library/Caches/ConversationCache")
        XCTAssertEqual(MuseAgentSessionAdapter.sessionID(at: dir.appendingPathComponent("hatch-main.json")), "hatch-main")
        XCTAssertNil(MuseAgentSessionAdapter.sessionID(at: dir.appendingPathComponent("0ca942de-1111-2222-3333-444444444444.json")))
        XCTAssertNil(MuseAgentSessionAdapter.sessionID(at: dir.appendingPathComponent("hatch-a.b.json")))
        XCTAssertNil(MuseAgentSessionAdapter.sessionID(at: dir.appendingPathComponent("hatch-$(x).json")))
    }

    // MARK: - Metadata

    func testMetadata() throws {
        let url = try writeMainChat()
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .museAgent)
        XCTAssertEqual(summary.harness, .museAgent)
        XCTAssertEqual(summary.effectiveHarness.displayName, "Muse")
        XCTAssertEqual(summary.sessionID, "hatch-main")
        XCTAssertEqual(summary.providerVariant, MuseAgentSessionAdapter.variant)
        XCTAssertNil(summary.model)
        XCTAssertNil(summary.projectDir)
        XCTAssertEqual(summary.title, "Plan the week for the garden club.")
        XCTAssertEqual(summary.summary, "Done: option a is booked.")
        // Every entry counts as a turn, including the empty streaming one.
        XCTAssertEqual(summary.messageCount, 5)
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: unixStart))
        XCTAssertEqual(summary.lastActiveAt, Date(timeIntervalSince1970: unixStart + 240))
        XCTAssertEqual(summary.sourcePath, url.path)
        XCTAssertGreaterThan(summary.sizeBytes, 0)
    }

    func testLongFirstPromptIsTruncatedToOneLine() throws {
        let long = "Line one\nline two " + String(repeating: "x", count: 200)
        let url = try write("hatch-main.json", messages: [
            message("m1", user: true, content: long, at: 0, seq: 1)
        ])
        let title = try XCTUnwrap(adapter.extractMetadata(fileURL: url).title)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertTrue(title.hasPrefix("Line one line two xxx"))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, SessionParsing.titleLimit + 1)
    }

    // MARK: - Transcript

    func testTranscriptFollowsSortSeqAndReadsMarkdownBlocks() throws {
        let url = try writeMainChat()
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(document.messages.map(\.text), [
            "Plan the week for the garden club.",
            "Three steps.\n\nFirst, read the notes.",
            "Pick option a.",
            "Done: option a is booked."
        ])
        XCTAssertEqual(document.messages.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(document.messages[1].timestamp, Date(timeIntervalSince1970: unixStart + 60))
        XCTAssertFalse(document.truncated)
    }

    func testTranscriptRange() throws {
        let url = try writeMainChat()
        let document = try adapter.parseTranscript(fileURL: url, range: 1..<3)
        XCTAssertEqual(document.messages.map(\.text), ["Three steps.\n\nFirst, read the notes.", "Pick option a."])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertTrue(document.truncated)
    }

    /// One entry without `sortSeq` means there is no total order to trust;
    /// the file's own order stands.
    func testMissingSortSeqKeepsFileOrder() throws {
        let url = try write("hatch-main.json", messages: [
            message("b", user: false, content: "second", at: 60, seq: 9),
            message("a", user: true, content: "first", at: 0, seq: nil)
        ])
        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.map(\.text), ["second", "first"])
    }

    func testContentWinsOverBlocks() throws {
        let url = try write("hatch-main.json", messages: [
            message("a", user: false, content: "plain", at: 0, seq: 1, blocks: [
                ["markdown": ["text": "rich", "inlineEntities": []]]
            ])
        ])
        XCTAssertEqual(try adapter.parseTranscript(fileURL: url, range: nil).messages.map(\.text), ["plain"])
    }

    // MARK: - Apple reference-date timestamps

    func testTimestampsAreAppleReferenceSeconds() {
        XCTAssertEqual(
            MuseAgentSessionAdapter.date(NSNumber(value: referenceStart)),
            Date(timeIntervalSince1970: unixStart)
        )
        XCTAssertEqual(
            MuseAgentSessionAdapter.date(NSNumber(value: 811_480_307.25)),
            Date(timeIntervalSince1970: 811_480_307.25 + 978_307_200)
        )
        XCTAssertNil(MuseAgentSessionAdapter.date(true))
        XCTAssertNil(MuseAgentSessionAdapter.date(NSNumber(value: 0)))
        XCTAssertNil(MuseAgentSessionAdapter.date(NSNumber(value: -5)))
        XCTAssertNil(MuseAgentSessionAdapter.date(NSNumber(value: referenceStart * 1000)))
        XCTAssertNil(MuseAgentSessionAdapter.date("788918400"))
        XCTAssertNil(MuseAgentSessionAdapter.date(nil))
    }

    // MARK: - Deletion

    func testDeletionFailsClosed() throws {
        let summary = try adapter.extractMetadata(fileURL: writeMainChat())
        XCTAssertFalse(SessionProvider.museAgent.supportsDeletion)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.museAgent))
        }
        let outcomes = SessionDeleter().delete(
            [summary], registry: .standard(homeDirectory: home.path)
        )
        XCTAssertFalse(outcomes[0].success)
        XCTAssertEqual(outcomes[0].failureReason, .providerIsReadOnly(.museAgent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.sourcePath))
    }

    // MARK: - Malformed input

    func testNumericIsUserIsNotAMessage() throws {
        // `0` / `1` bridge through `is Bool`; a numeric flag is not this
        // store's shape and must not be given an invented role.
        let url = try write("hatch-main.json", """
        [{"id":"a","isUser":1,"content":"numeric user","timestamp":\(referenceStart)},
         {"id":"b","isUser":0,"content":"numeric reply","timestamp":\(referenceStart + 1)},
         {"id":"c","isUser":true,"content":"real prompt","timestamp":\(referenceStart + 2)}]
        """)
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.messageCount, 1)
        XCTAssertEqual(summary.title, "real prompt")
        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.map(\.text), ["real prompt"])
        XCTAssertEqual(document.messages.map(\.role), [.user])
    }

    func testMalformedFilesFailWithTheTwoParseErrors() throws {
        let truncated = try write("hatch-main.json", "[{\"id\":\"a\",\"isUser\":tr")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: truncated)) { error in
            guard case .unreadable = error as? SessionParseError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try adapter.parseTranscript(fileURL: truncated, range: nil))

        let object = try write("hatch-object.json", "{\"messages\":[]}")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: object)) { error in
            guard case .invalidFormat = error as? SessionParseError else { return XCTFail("\(error)") }
        }

        let empty = try write("hatch-empty.json", "[]")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: empty)) { error in
            guard case .unreadable = error as? SessionParseError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try adapter.parseTranscript(fileURL: empty, range: nil).messages, [])

        let foreign = try write("0ca942de-1111-2222-3333-444444444444.json", "[]")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: foreign)) { error in
            guard case .invalidFormat = error as? SessionParseError else { return XCTFail("\(error)") }
        }

        let missing = storeDirectory.appendingPathComponent("hatch-gone.json")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: missing))
    }

    /// Wrong types in every field: skipped, never a crash, and the one good
    /// entry still reads.
    func testJunkEntriesAreSkipped() throws {
        let url = try write("hatch-main.json", """
        [
          1, "text", null, [],
          {"id":"x","content":"no isUser flag","timestamp":788918400},
          {"id":"y","isUser":"yes","content":"isUser is a string"},
          {"id":"z","isUser":false,"content":42,"contentBlocks":"nope","timestamp":"soon","sortSeq":"one"},
          {"id":"w","isUser":false,"content":"","contentBlocks":[1,{"markdown":"flat"},{"markdown":{"text":7}},{"unsupported":{}}]},
          {"id":"ok","isUser":true,"content":"  the one good line  ","timestamp":788918460,"sortSeq":2}
        ]
        """)
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertEqual(summary.title, "the one good line")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: unixStart + 60))
        XCTAssertEqual(summary.lastActiveAt, Date(timeIntervalSince1970: unixStart + 60))

        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.map(\.text), ["the one good line"])
        XCTAssertEqual(document.messages.map(\.role), [.user])
    }

    // MARK: - Registry

    func testRegisteredInTheStandardRegistry() {
        let registry = SessionProviderRegistry.standard(homeDirectory: "/Users/example")
        XCTAssertTrue(registry.adapter(for: .museAgent) is MuseAgentSessionAdapter)
        XCTAssertTrue(registry.adapter(for: .muse) is MuseSessionAdapter)
    }
}
