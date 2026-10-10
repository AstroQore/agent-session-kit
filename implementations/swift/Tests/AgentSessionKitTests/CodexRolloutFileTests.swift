import XCTest
@testable import AgentSessionKit

final class CodexRolloutFileTests: XCTestCase {
    private let plain = "rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589.jsonl"
    private let compressed = "rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589.jsonl.zst"

    func testBothSpellingsAreRollouts() {
        XCTAssertTrue(CodexRolloutFile.isRolloutName(plain))
        XCTAssertTrue(CodexRolloutFile.isRolloutName(compressed))
        XCTAssertFalse(CodexRolloutFile.isRolloutName("rollout-x.jsonl.zst.partial"))
        XCTAssertFalse(CodexRolloutFile.isRolloutName("rollout-compression.lock"))
        XCTAssertFalse(CodexRolloutFile.isRolloutName("notes.jsonl"))
    }

    func testStemDropsEitherSuffix() {
        let stem = "rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589"
        XCTAssertEqual(CodexRolloutFile.stem(ofName: plain), stem)
        XCTAssertEqual(CodexRolloutFile.stem(ofName: compressed), stem)
        XCTAssertEqual(CodexRolloutFile.stem(ofName: "other.txt"), "other.txt")
    }

    func testCanonicalPathStripsOnlyTheCompressedSuffix() {
        XCTAssertEqual(CodexRolloutFile.canonicalPath("/a/b/\(compressed)"), "/a/b/\(plain)")
        XCTAssertEqual(CodexRolloutFile.canonicalPath("/a/b/\(plain)"), "/a/b/\(plain)")
        XCTAssertEqual(CodexRolloutFile.canonicalPath("/a/b/archive.zst"), "/a/b/archive.zst")
    }

    func testIsJSONLAcceptsCompressed() {
        XCTAssertTrue(CodexRolloutFile.isJSONL(URL(fileURLWithPath: "/x/\(compressed)")))
        XCTAssertTrue(CodexRolloutFile.isCompressed(URL(fileURLWithPath: "/x/\(compressed)")))
        XCTAssertFalse(CodexRolloutFile.isCompressed(URL(fileURLWithPath: "/x/\(plain)")))
        XCTAssertFalse(CodexRolloutFile.isJSONL(URL(fileURLWithPath: "/x/state.sqlite")))
    }
}
