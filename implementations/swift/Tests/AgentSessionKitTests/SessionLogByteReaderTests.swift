import XCTest
@testable import AgentSessionKit

final class SessionLogByteReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASKByteReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func readAll(_ url: URL, chunk: Int = 64 * 1024) throws -> Data {
        let reader = try XCTUnwrap(SessionLogByteReader(url: url))
        defer { reader.close() }
        var out = Data()
        while let piece = try reader.read(upToCount: chunk) { out.append(piece) }
        return out
    }

    /// `n` lines of varied, non-repeating text, large enough to span
    /// several raw blocks and several decoder output buffers.
    private func bigLog(lines n: Int) -> Data {
        var text = ""
        text.reserveCapacity(n * 80)
        for index in 0..<n {
            text += #"{"line":\#(index),"payload":"\#(String(repeating: "x", count: index % 97))"}"# + "\n"
        }
        return Data(text.utf8)
    }

    // MARK: - Decoding

    func testCLICompressedRolloutDecodesToOriginalBytes() throws {
        let url = file("rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589.jsonl.zst")
        try ZstdTestFrame.cliCompressedRollout.write(to: url)
        let reader = try XCTUnwrap(SessionLogByteReader(url: url))
        XCTAssertTrue(reader.isCompressed)
        reader.close()

        let expected = Data((ZstdTestFrame.cliCompressedRolloutLines.joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(try readAll(url), expected)
        XCTAssertEqual(try readAll(url, chunk: 7), expected, "tiny output buffers must not lose bytes")
    }

    func testRawFramesSpanningManyBlocksRoundTrip() throws {
        let content = bigLog(lines: 20_000)
        XCTAssertGreaterThan(content.count, 3 * ZstdTestFrame.maxBlockSize)
        let url = file("big.jsonl.zst")
        try ZstdTestFrame.write(content, to: url)
        XCTAssertEqual(try readAll(url), content)
        XCTAssertEqual(try readAll(url, chunk: 1000), content)
    }

    func testEmptyFrameReadsAsEmpty() throws {
        let url = file("empty.jsonl.zst")
        try ZstdTestFrame.write(Data(), to: url)
        XCTAssertEqual(try readAll(url), Data())
    }

    func testPlainFileIsPassedThrough() throws {
        let url = file("plain.jsonl")
        let content = bigLog(lines: 10)
        try content.write(to: url)
        let reader = try XCTUnwrap(SessionLogByteReader(url: url))
        XCTAssertFalse(reader.isCompressed)
        reader.close()
        XCTAssertEqual(try readAll(url), content)
    }

    func testMissingFileReturnsNilReader() {
        XCTAssertNil(SessionLogByteReader(url: file("absent.jsonl.zst")))
        XCTAssertNil(SessionLogByteReader(url: file("absent.jsonl")))
    }

    func testTruncatedFrameThrows() throws {
        let content = bigLog(lines: 5_000)
        let whole = ZstdTestFrame.wrap(content)
        let url = file("cut.jsonl.zst")
        try whole.prefix(whole.count / 2).write(to: url)
        XCTAssertThrowsError(try readAll(url)) { error in
            XCTAssertEqual(error as? ZstdStreamDecoder.DecodeError, .truncated)
        }
    }

    func testGarbageThrowsCorrupt() throws {
        let url = file("garbage.jsonl.zst")
        try Data("this is not a zstd frame at all\n".utf8).write(to: url)
        XCTAssertThrowsError(try readAll(url)) { error in
            guard case .corrupt? = error as? ZstdStreamDecoder.DecodeError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    // MARK: - Seeking

    func testSeekForwardAndBackwardUsesDecompressedOffsets() throws {
        let content = bigLog(lines: 20_000)
        let url = file("seek.jsonl.zst")
        try ZstdTestFrame.write(content, to: url)
        let reader = try XCTUnwrap(SessionLogByteReader(url: url))
        defer { reader.close() }

        let bytes = [UInt8](content)
        try reader.seek(toOffset: 300_000)
        XCTAssertEqual([UInt8](try XCTUnwrap(reader.read(upToCount: 16))), Array(bytes[300_000..<300_016]))

        try reader.seek(toOffset: 1_000)
        XCTAssertEqual([UInt8](try XCTUnwrap(reader.read(upToCount: 16))), Array(bytes[1_000..<1_016]))

        try reader.seek(toOffset: Int64(bytes.count) + 10)
        XCTAssertNil(try reader.read(upToCount: 16), "a seek past the end reads nothing")
    }

    // MARK: - Line helpers on compressed logs

    func testLineScannerAndHeadTailReadCompressedLogs() throws {
        let lines = (0..<500).map { #"{"i":\#($0)}"# }
        let url = file("lines.jsonl.zst")
        try ZstdTestFrame.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: url)

        var seen: [String] = []
        XCTAssertTrue(JSONLLineScanner.forEachLine(in: url) { seen.append(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(seen, lines)

        XCTAssertEqual(
            JSONLHeadTail.headLines(url: url, count: 3).map { String(decoding: $0, as: UTF8.self) },
            Array(lines.prefix(3))
        )
        XCTAssertEqual(
            JSONLHeadTail.tailLines(url: url, count: 4).map { String(decoding: $0, as: UTF8.self) },
            Array(lines.suffix(4))
        )
        XCTAssertEqual(JSONLHeadTail.lineCountIfSmall(url: url), 500)
        XCTAssertNil(JSONLHeadTail.lineCountIfSmall(url: url, maxBytes: 16), "the on-disk bound still applies")
    }

    func testHeadLinesHonoursByteBudgetOnCompressedLogs() throws {
        let lines = (0..<50).map { #"{"i":\#($0),"pad":"\#(String(repeating: "p", count: 100))"}"# }
        let url = file("budget.jsonl.zst")
        try ZstdTestFrame.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: url)
        let head = JSONLHeadTail.headLines(url: url, count: 10, maxBytes: 300)
        XCTAssertEqual(head.count, 2, "only the complete lines inside the budget")
    }
}
