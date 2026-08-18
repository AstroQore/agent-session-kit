import XCTest
@testable import AgentSessionKit

final class PrivacyPreservingHashTests: XCTestCase {
    func testFileComponentIsDeterministic() {
        let raw = "/Users/example/.codex/sessions/abc.jsonl"
        let a = PrivacyPreservingHash.fileComponent(prefix: "session-path-v1", rawValue: raw)
        let b = PrivacyPreservingHash.fileComponent(prefix: "session-path-v1", rawValue: raw)
        XCTAssertEqual(a, b)
    }

    func testFileComponentDiffersByRawValue() {
        let a = PrivacyPreservingHash.fileComponent(prefix: "p", rawValue: "one")
        let b = PrivacyPreservingHash.fileComponent(prefix: "p", rawValue: "two")
        XCTAssertNotEqual(a, b)
    }

    func testFileComponentIsPrefixedAndNeverContainsTheRawValue() {
        let raw = "/Users/example/.codex/sessions/abc.jsonl"
        let component = PrivacyPreservingHash.fileComponent(prefix: "session-path-v1", rawValue: raw)

        XCTAssertTrue(component.hasPrefix("session-path-v1-"))
        XCTAssertFalse(component.contains(raw))

        // A SHA-256 digest is 32 bytes, i.e. 64 lowercase hex characters.
        let digest = component.dropFirst("session-path-v1-".count)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
        XCTAssertEqual(String(digest), digest.lowercased())
    }
}
