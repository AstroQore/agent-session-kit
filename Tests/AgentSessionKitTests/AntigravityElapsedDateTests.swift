import XCTest
@testable import AgentSessionKit

/// agy CLI builds from ~1.1.18 (2026-08) stopped writing the per-turn wall
/// clock (`1.9.4`) and record a relative offset instead: milliseconds since
/// the trajectory started, at `1.9.10.1`, with the base clock in the store's
/// own `trajectory_metadata_blob` table (path `2.1`). These tests pin the
/// recovery: base + offset dates the turn; no base keeps the old strict
/// behavior.
final class AntigravityElapsedDateTests: XCTestCase {
    private var directory: URL!
    private let baseSeconds: UInt64 = 1_787_918_657

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ask-ag-elapsed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func databaseURL(_ name: String = "conversation.db") -> URL {
        directory.appendingPathComponent(name)
    }

    func testRelativeTurnsDateFromTrajectoryBase() throws {
        let url = databaseURL()
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 24_928, input: 100, output: 40)),
                .init(idx: 1, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 40_241, input: 220, output: 75))
            ],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        let turns = AntigravityGenMetadataReader.readGenMetadata(at: url)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(
            turns[0].date.timeIntervalSince1970,
            TimeInterval(baseSeconds) + 24.928,
            accuracy: 0.001
        )
        XCTAssertEqual(
            turns[1].date.timeIntervalSince1970,
            TimeInterval(baseSeconds) + 40.241,
            accuracy: 0.001
        )
        // Usage decoding is untouched by how the clock resolved.
        XCTAssertEqual(turns[0].inputTokens, 100)
        XCTAssertEqual(turns[1].outputTokens, 75)
        XCTAssertEqual(turns[0].requestId, "req-fixture")
    }

    func testRelativeTurnsWithoutBaseAreStillDropped() throws {
        let url = databaseURL()
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 5_000, input: 10, output: 5))
            ]
        )
        XCTAssertTrue(AntigravityGenMetadataReader.readGenMetadata(at: url).isEmpty)
    }

    func testAbsoluteTurnsKeepTheirOwnClockOverTheBase() throws {
        let url = databaseURL()
        let absolute: UInt64 = 1_760_000_123
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.turnBlob(
                    seconds: absolute, input: 10, output: 5))
            ],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        let turns = AntigravityGenMetadataReader.readGenMetadata(at: url)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].date, Date(timeIntervalSince1970: TimeInterval(absolute)))
    }

    func testMixedStoreDatesBothForms() throws {
        let url = databaseURL()
        let absolute: UInt64 = 1_760_000_123
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.turnBlob(
                    seconds: absolute, input: 1, output: 1)),
                .init(idx: 1, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 1_500, input: 2, output: 2))
            ],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        let turns = AntigravityGenMetadataReader.readGenMetadata(at: url)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].date, Date(timeIntervalSince1970: TimeInterval(absolute)))
        XCTAssertEqual(
            turns[1].date.timeIntervalSince1970,
            TimeInterval(baseSeconds) + 1.5,
            accuracy: 0.001
        )
    }

    func testFirstInstantElidedElapsedDatesAtTheBase() throws {
        // proto3 elides a zero: a relative block with no field 1 is the
        // trajectory's first instant, not an undatable row.
        let url = databaseURL()
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: nil, input: 3, output: 4))
            ],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        let turns = AntigravityGenMetadataReader.readGenMetadata(at: url)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(
            turns[0].date.timeIntervalSince1970,
            TimeInterval(baseSeconds),
            accuracy: 0.001
        )
    }

    func testBareDecodeTurnStillRefusesARelativeBlob() {
        let blob = AntigravityProtoFixture.relativeTurnBlob(
            elapsedMilliseconds: 7_000, input: 1, output: 1
        )
        XCTAssertNil(AntigravityGenMetadataReader.decodeTurn(blob: blob))
        let base = Date(timeIntervalSince1970: TimeInterval(baseSeconds))
        let dated = AntigravityGenMetadataReader.decodeTurn(blob: blob, baseDate: base)
        XCTAssertEqual(
            dated?.date.timeIntervalSince1970 ?? 0,
            TimeInterval(baseSeconds) + 7,
            accuracy: 0.001
        )
    }

    func testTrajectoryBaseDateReadsTheStore() throws {
        let url = databaseURL()
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        XCTAssertEqual(
            AntigravityGenMetadataReader.trajectoryBaseDate(at: url)?.timeIntervalSince1970 ?? 0,
            TimeInterval(baseSeconds),
            accuracy: 0.001
        )
        let bare = databaseURL("no-base.db")
        try AntigravityDBFixture.write(at: bare, steps: [])
        XCTAssertNil(AntigravityGenMetadataReader.trajectoryBaseDate(at: bare))
    }

    func testLiveMetadataSummaryDatesRelativeTurns() throws {
        let url = databaseURL()
        try AntigravityDBFixture.write(
            at: url,
            steps: [],
            turns: [
                .init(idx: 0, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 2_000, input: 5, output: 5)),
                .init(idx: 1, blob: AntigravityProtoFixture.relativeTurnBlob(
                    elapsedMilliseconds: 9_000, input: 6, output: 6))
            ],
            trajectoryBase: AntigravityProtoFixture.trajectoryBaseBlob(seconds: baseSeconds)
        )
        let summary = try XCTUnwrap(AntigravityLiveSQLite.metadataSummary(at: url))
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(
            summary.firstDate?.timeIntervalSince1970 ?? 0,
            TimeInterval(baseSeconds) + 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            summary.lastDate?.timeIntervalSince1970 ?? 0,
            TimeInterval(baseSeconds) + 9,
            accuracy: 0.001
        )
    }
}
